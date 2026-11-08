import Darwin
import Foundation

public enum ItemStatus: String, Codable, Sendable {
    case removed, trashed, partial, protectedByMacOS, blocked, failed, alreadyGone

    public var label: String {
        switch self {
        case .removed: "Removed"
        case .trashed: "Moved to Trash"
        case .partial: "Partly removed"
        case .protectedByMacOS: "Protected by macOS"
        case .blocked: "Skipped for safety"
        case .failed: "Failed"
        case .alreadyGone: "Already gone"
        }
    }
}

public struct ItemResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String { itemID }
    public var itemID: String
    public var title: String
    public var status: ItemStatus
    public var removedPaths: Int
    public var protectedPaths: Int
    public var failedPaths: Int
    public var message: String
    public var expectedBytes: Int64

    public init(itemID: String, title: String, status: ItemStatus, removedPaths: Int, protectedPaths: Int,
                failedPaths: Int, message: String, expectedBytes: Int64) {
        self.itemID = itemID; self.title = title; self.status = status; self.removedPaths = removedPaths
        self.protectedPaths = protectedPaths; self.failedPaths = failedPaths; self.message = message; self.expectedBytes = expectedBytes
    }
}

public enum ExecutionEvent: Sendable {
    case started(Item)
    case log(String)
    case finished(ItemResult)
}

/// Executes a confirmed plan, one item at a time. No shell; every action re-checked by SafetyGuard first.
public final class Executor: Sendable {
    public let guardian: SafetyGuard
    public let context: DetectionContext
    public let logURL: URL

    public static func defaultLogURL(now: Date = Date()) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sweep/sweep-\(f.string(from: now)).log")
    }

    public init(guardian: SafetyGuard, context: DetectionContext, logURL: URL = Executor.defaultLogURL()) {
        self.guardian = guardian; self.context = context; self.logURL = logURL
    }

    public func execute(_ plan: Plan) -> AsyncStream<ExecutionEvent> {
        AsyncStream { cont in
            let task = Task {
                for entry in plan.entries where entry.selected {
                    if Task.isCancelled { break }
                    cont.yield(.started(entry.item))
                    let result = await self.run(entry.item) { cont.yield(.log($0)) }
                    self.log("\(result.status.rawValue)\t\(entry.item.title)\t\(entry.item.path)\t\(result.message)")
                    cont.yield(.finished(result))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func run(_ item: Item, log emit: @Sendable (String) -> Void) async -> ItemResult {
        func result(_ s: ItemStatus, removed: Int = 0, protected: Int = 0, failed: Int = 0, bytes: Int64? = nil, _ msg: String) -> ItemResult {
            ItemResult(itemID: item.id, title: item.title, status: s, removedPaths: removed, protectedPaths: protected,
                       failedPaths: failed, message: msg, expectedBytes: bytes ?? item.physicalBytes)
        }
        // Something else removed it after the scan: nothing to do, and nothing freed by us.
        if item.action == .hardDelete || item.action == .trash {
            var st = stat()
            if lstat(item.path, &st) != 0, errno == ENOENT {
                emit("\(item.title) was already gone")
                return result(.alreadyGone, bytes: 0, "It was already gone (something else removed it after the scan)")
            }
        }
        if case let .blocked(reason) = await guardian.check(item) {
            emit("Skipped \(item.title): \(reason)")
            return result(.blocked, reason)
        }
        emit("→ \(item.action.preview(path: item.path))")
        switch item.action {
        case .hardDelete:
            let t = await Self.deleteTreeAsync(item.path)
            let status: ItemStatus = t.protected == 0 && t.failed == 0 ? .removed
                : t.removed > 0 ? .partial : t.failed == 0 ? .protectedByMacOS : .failed
            var msg = "\(t.removed) removed"
            if t.protected > 0 { msg += ", \(t.protected) protected by macOS" }
            if t.failed > 0 { msg += ", \(t.failed) failed (\(t.firstError ?? "unknown error"))" }
            // Only a fully removed item counts its scanned size; otherwise count what was actually unlinked.
            let bytes = status == .removed ? item.physicalBytes : min(t.freedBytes, item.physicalBytes)
            return result(status, removed: t.removed, protected: t.protected, failed: t.failed, bytes: bytes, msg)
        case .trash:
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                return result(.trashed, removed: 1, "Moved to the Trash. Empty the Trash to free the space.")
            } catch { return result(.failed, failed: 1, "Couldn't move to the Trash: \(error.localizedDescription)") }
        case let .toolCommand(exe, args):
            let r = await context.runner.run(exe, args, timeout: 1800)
            if !r.stdout.isEmpty { emit(String(r.stdout.suffix(2000))) }
            return r.ok ? result(.removed, removed: 1, "Done") : result(.failed, failed: 1, Self.tail(r))
        case let .dockerCommand(args):
            guard let docker = context.tools.path(for: "docker") else { return result(.failed, failed: 1, "Docker isn't installed") }
            let r = await context.runner.run(docker, args, timeout: 1800)
            if !r.stdout.isEmpty { emit(String(r.stdout.suffix(2000))) }
            let trimOK = args == DockerDetector.trimArguments && r.stdout.contains("trimmed")
            return r.ok || trimOK ? result(.removed, removed: 1, "Done") : result(.failed, failed: 1, Self.tail(r))
        case let .gitWorktreeRemove(repo):
            guard let git = context.tools.path(for: "git") else { return result(.failed, failed: 1, "git isn't installed") }
            let r = await context.runner.run(git, ["-C", repo, "worktree", "remove", item.path], timeout: 300)
            return r.ok ? result(.removed, removed: 1, "Worktree removed; the branch is kept") : result(.failed, failed: 1, Self.tail(r))
        case .none, .revealInFinder:
            return result(.blocked, "Not actionable")
        }
    }

    static func tail(_ r: CommandResult) -> String {
        if r.timedOut { return "Timed out" }
        let s = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return "Exit \(r.exitCode): " + String(s.suffix(400))
    }

    struct TreeResult: Sendable { var removed = 0; var protected = 0; var failed = 0; var freedBytes: Int64 = 0; var firstError: String? }

    /// `deleteTree` blocks for as long as the filesystem takes; keep it off Swift's cooperative thread pool.
    static func deleteTreeAsync(_ root: String) async -> TreeResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: deleteTree(root)) }
        }
    }

    /// Bottom-up delete without following symlinks; each path's outcome counted individually.
    static func deleteTree(_ root: String) -> TreeResult {
        var t = TreeResult()
        func classify(_ err: Int32, _ path: String) {
            if err == EPERM || err == EACCES || err == EROFS { t.protected += 1 } else {
                t.failed += 1
                if t.firstError == nil { t.firstError = "\(path): \(String(cString: strerror(err)))" }
            }
        }
        func visit(_ path: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            if st.st_mode & S_IFMT == S_IFDIR {
                if let kids = RealFileSystemProbe().children(path) {
                    for k in kids { visit(path + "/" + k) }
                } else { classify(errno, path); return }
                if rmdir(path) != 0, errno != ENOTEMPTY, errno != EEXIST { classify(errno, path) }
            } else {
                if unlink(path) == 0 {
                    t.removed += 1
                    if st.st_nlink <= 1 { t.freedBytes += Int64(st.st_blocks) * 512 }   // other hard links keep the data alive
                } else { classify(errno, path) }
            }
        }
        visit(root)
        return t
    }

    func log(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = ISO8601DateFormatter().string(from: Date()) + "\t" + line + "\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}
