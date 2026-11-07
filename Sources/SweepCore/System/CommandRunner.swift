import Foundation

public struct CommandResult: Sendable, Hashable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var ok: Bool { exitCode == 0 && !timedOut }
    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }
}

/// Runs an external program directly (no shell). Implementations must never use `sh -c`.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
             environment: [String: String]?, currentDirectory: String?) async -> CommandResult
}

public extension CommandRunner {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60) async -> CommandResult {
        await run(executable, arguments, timeout: timeout, environment: nil, currentDirectory: nil)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func set(_ d: Data) { lock.lock(); value = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    environment: [String: String]?, currentDirectory: String?) async -> CommandResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: Self.runSync(executable, arguments, timeout, environment, currentDirectory))
            }
        }
    }

    static func runSync(_ executable: String, _ arguments: [String], _ timeout: TimeInterval,
                        _ environment: [String: String]?, _ cwd: String?) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return CommandResult(exitCode: 127, stdout: "", stderr: "\(executable): not found or not executable")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        var env = environment ?? ProcessInfo.processInfo.environment
        // Tools spawned from a GUI app get a minimal PATH; give them a sane one.
        let basePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\($0):\(basePath)" } ?? basePath
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() } catch {
            return CommandResult(exitCode: 127, stdout: "", stderr: "failed to launch \(executable): \(error.localizedDescription)")
        }
        let outBox = DataBox(), errBox = DataBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { outBox.set(out.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { errBox.set(err.fileHandleForReading.readDataToEndOfFile()); readers.leave() }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }
        // Grandchildren may keep the pipes open; don't wait forever for EOF.
        if readers.wait(timeout: .now() + (timedOut ? 1 : 5)) == .timedOut {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        let code: Int32 = p.isRunning ? -9 : p.terminationStatus
        return CommandResult(
            exitCode: code,
            stdout: String(decoding: outBox.get(), as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self),
            timedOut: timedOut)
    }
}
