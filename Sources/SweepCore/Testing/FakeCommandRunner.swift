import Foundation

/// Deterministic runner for tests and previews. Keyed by "executable arg1 arg2".
public final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: CommandResult]
    private var _calls: [String] = []
    private var _invocations: [Invocation] = []
    public struct Invocation: Sendable { public var executable: String; public var arguments: [String]; public var currentDirectory: String? }
    public var fallback: CommandResult

    public init(_ responses: [String: CommandResult] = [:],
                fallback: CommandResult = CommandResult(exitCode: 1, stdout: "", stderr: "not stubbed")) {
        self.responses = responses; self.fallback = fallback
    }

    public func stub(_ key: String, _ result: CommandResult) { lock.lock(); responses[key] = result; lock.unlock() }
    public func stub(_ key: String, stdout: String) { stub(key, CommandResult(exitCode: 0, stdout: stdout, stderr: "")) }
    public var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    public var invocations: [Invocation] { lock.lock(); defer { lock.unlock() }; return _invocations }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    environment: [String: String]?, currentDirectory: String?) async -> CommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        return lock.withLock {
            _calls.append(key)
            _invocations.append(Invocation(executable: executable, arguments: arguments, currentDirectory: currentDirectory))
            return responses[key] ?? fallback
        }
    }
}
