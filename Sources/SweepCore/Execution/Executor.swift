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
            let clean = t.protected == 0 && t.failed == 0 && t.otherVolume == 0 && !t.leftBehind
            let status: ItemStatus = clean ? .removed
                : t.removed > 0 ? .partial : t.failed == 0 && t.protected > 0 ? .protectedByMacOS : .failed
            var msg = "\(t.removed) removed"
            if t.protected > 0 { msg += ", \(t.protected) protected by macOS" }
            if t.otherVolume > 0 { msg += ", \(t.otherVolume) on another disk left alone" }
            if t.leftBehind { msg += ", new files appeared while deleting and were left" }
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
            guard r.ok else { return result(.failed, failed: 1, Self.tail(r)) }
            // Cleanup commands often remove only part of a cache: count what actually went.
            guard item.path.hasPrefix("/") else { return result(.removed, removed: 1, "Done") }
            let after = await Self.measureAsync(context, item.path)
            let freed = max(0, item.physicalBytes - after)
            return result(.removed, removed: 1, bytes: freed, "Done, freed \(ByteFormat.string(freed))")
        case let .dockerCommand(args):
            guard let docker = context.tools.path(for: "docker") else { return result(.failed, failed: 1, "Docker isn't installed") }
            let r = await DockerDetector.run(context.runner, docker, args, timeout: 1800)
            if !r.stdout.isEmpty { emit(String(r.stdout.suffix(2000))) }
            let trimOK = args == DockerDetector.trimArguments && r.stdout.contains("trimmed")
            return r.ok || trimOK
                ? result(.removed, removed: 1, "Done. Docker doesn't report exactly what it freed, so the real gain can be smaller")
                : result(.failed, failed: 1, Self.tail(r))
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

    struct TreeResult: Sendable { var removed = 0; var protected = 0; var failed = 0; var otherVolume = 0; var leftBehind = false; var freedBytes: Int64 = 0; var firstError: String? }

    /// Physical size of `path` now (0 when it's gone), measured off the cooperative pool.
    static func measureAsync(_ ctx: DetectionContext, _ path: String) async -> Int64 {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: ctx.probe.meta(path) == nil ? 0 : ctx.measure(path).physical) }
        }
    }

    /// `deleteTree` blocks for as long as the filesystem takes; keep it off Swift's cooperative thread pool.
    static func deleteTreeAsync(_ root: String) async -> TreeResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: deleteTree(root)) }
        }
    }

    /// Bottom-up delete, each path's outcome counted individually.
    /// Works relative to open directory handles (`openat`/`unlinkat` with `O_NOFOLLOW`), so a folder swapped for a
    /// link mid-delete is never followed, and it never crosses into another volume mounted inside the tree.
    static func deleteTree(_ root: String, beforeRemovingDirectory: ((String) -> Void)? = nil) -> TreeResult {
        var t = TreeResult()
        func classify(_ err: Int32, _ path: String) {
            if err == EPERM || err == EACCES || err == EROFS { t.protected += 1 } else {
                t.failed += 1
                if t.firstError == nil { t.firstError = "\(path): \(String(cString: strerror(err)))" }
            }
        }
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { return t }
        let rootDev = rootStat.st_dev
        let parentFD = open((root as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { classify(errno, root); return t }
        defer { close(parentFD) }

        func visit(_ dirFD: Int32, _ name: String, _ path: String) {
            var st = stat()
            guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return }
            if st.st_mode & S_IFMT == S_IFDIR {
                if st.st_dev != rootDev { t.otherVolume += 1; return }   // a mounted volume: never ours to delete
                let fd = openat(dirFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { classify(errno, path); return }
                var opened = stat()
                guard fstat(fd, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else {
                    close(fd); t.failed += 1
                    if t.firstError == nil { t.firstError = "\(path): changed while deleting" }
                    return
                }
                for kid in Self.names(in: fd) { visit(fd, kid, path + "/" + kid) }
                close(fd)
                beforeRemovingDirectory?(path)
                if unlinkat(dirFD, name, AT_REMOVEDIR) != 0, errno != ENOTEMPTY, errno != EEXIST { classify(errno, path) }
            } else {
                if unlinkat(dirFD, name, 0) == 0 {
                    t.removed += 1
                    if st.st_nlink <= 1 { t.freedBytes += Int64(st.st_blocks) * 512 }   // other hard links keep the data alive
                } else { classify(errno, path) }
            }
        }
        visit(parentFD, (root as NSString).lastPathComponent, root)
        // Nothing failed, yet the folder is still there: something wrote into it while Sweep was deleting.
        var after = stat()
        if t.protected == 0, t.failed == 0, t.otherVolume == 0, lstat(root, &after) == 0 { t.leftBehind = true }
        return t
    }

    /// Entry names of an open directory (without "." and ".."). Reads a duplicate handle so `fd` stays usable.
    static func names(in fd: Int32) -> [String] {
        let dupFD = dup(fd)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else { if dupFD >= 0 { close(dupFD) }; return [] }
        defer { closedir(dir) }
        var out: [String] = []
        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(ent.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
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
