import Foundation

/// Claude through the user's own Claude Code install (`claude -p`), using whatever account Claude Code is signed in with.
/// No API key is stored by Sweep.
///
/// Locked down on purpose: `--tools ""` (no tools, so it cannot read files or run commands), `--safe-mode`
/// (no CLAUDE.md, hooks, plugins, skills or MCP servers), `--strict-mcp-config`, no saved session, and an empty
/// scratch folder as the working directory. The redacted summary is the only input.
public struct ClaudeCodeProvider: InsightsProvider {
    public static let defaultModel = "sonnet"
    public static let timeout: TimeInterval = 300

    public let executable: String
    public let model: String
    public let runner: CommandRunner

    public init(executable: String, model: String = ClaudeCodeProvider.defaultModel, runner: CommandRunner = ProcessCommandRunner()) {
        self.executable = executable; self.model = model; self.runner = runner
    }

    /// Where Claude Code usually lives: Homebrew/npm global bins (via the tool locator), then its own installers' folders.
    public static func candidatePaths(home: String) -> [String] {
        ["\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.volta/bin/claude"]
    }

    public static func locate(tools: ToolLocating = ToolLocator(), home: String = NSHomeDirectory()) -> String? {
        if let p = tools.path(for: "claude") { return p }
        return candidatePaths(home: home).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func arguments(system: String, user: String, schema schemaObject: [String: Any] = InsightsContract.jsonSchema) -> [String] {
        let schema = (try? JSONSerialization.data(withJSONObject: schemaObject, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ["-p", "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                "--output-format", "json", "--model", model, "--effort", "medium",
                "--system-prompt", system, "--json-schema", schema, user]
    }

    static func scratchDirectory() -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("SweepInsights")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    public func complete(system: String, user: String, schema: [String: Any]) async throws -> String {
        let r = await runner.run(executable, arguments(system: system, user: user, schema: schema), timeout: Self.timeout,
                                 environment: nil, currentDirectory: Self.scratchDirectory())
        if r.timedOut { throw InsightsError.claudeCode("timed out") }
        let envelope = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))) as? [String: Any]
        if let envelope {
            let result = envelope["result"] as? String ?? ""
            if envelope["is_error"] as? Bool == true {
                throw InsightsError.claudeCode(result.isEmpty ? (envelope["subtype"] as? String ?? "error") : result)
            }
            if let structured = envelope["structured_output"], JSONSerialization.isValidJSONObject(structured),
               let data = try? JSONSerialization.data(withJSONObject: structured) {
                return String(decoding: data, as: UTF8.self)
            }
            if !result.isEmpty { return result }
        }
        if !r.ok {
            let detail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InsightsError.claudeCode("exit \(r.exitCode)\(detail.isEmpty ? "" : ": \(detail.prefix(300))")")
        }
        throw InsightsError.notJSON
    }
}
