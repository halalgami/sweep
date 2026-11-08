import Foundation
import Testing
@testable import SweepCore

@Suite struct ClaudeCodeProviderTests {
    let answer = #"{"headline":"Caches regrew","insights":[],"recommendations":[],"maintenanceSuggestions":[],"questionsForUser":[]}"#

    func envelope(structured: String?, result: String = "", isError: Bool = false) -> String {
        var s = #"{"type":"result","subtype":"success","is_error":\#(isError),"result":\#(String(reflecting: result))"#
        if let structured { s += #","structured_output":\#(structured)"# }
        return s + "}"
    }

    @Test func runsHeadlessWithNoToolsAndReturnsStructuredOutput() async throws {
        let runner = FakeCommandRunner(fallback: CommandResult(exitCode: 0, stdout: envelope(structured: answer), stderr: ""))
        let p = ClaudeCodeProvider(executable: "/opt/homebrew/bin/claude", model: "sonnet", runner: runner)
        let raw = try await p.complete(system: "SYS", user: "{\"items\":[]}")
        let decoded = try InsightsContract.validate(raw, knownIDs: []).get()
        #expect(decoded.headline == "Caches regrew")

        let call = try #require(runner.invocations.first)
        #expect(call.executable == "/opt/homebrew/bin/claude")
        let a = call.arguments
        #expect(a.contains("-p"))
        #expect(a.contains("--safe-mode"))                    // no CLAUDE.md, hooks, plugins or MCP servers
        #expect(a.contains("--strict-mcp-config"))
        #expect(a.contains("--no-session-persistence"))
        let tools = try #require(a.firstIndex(of: "--tools"))
        #expect(a[tools + 1] == "")                           // no tools at all: it can't read files or run commands
        let fmt = try #require(a.firstIndex(of: "--output-format"))
        #expect(a[fmt + 1] == "json")
        let model = try #require(a.firstIndex(of: "--model"))
        #expect(a[model + 1] == "sonnet")
        let sys = try #require(a.firstIndex(of: "--system-prompt"))
        #expect(a[sys + 1] == "SYS")
        let schema = try #require(a.firstIndex(of: "--json-schema"))
        #expect(a[schema + 1].contains("\"headline\""))
        #expect(a.last == "{\"items\":[]}")
        #expect(!a.contains("--dangerously-skip-permissions"))
        // Runs in an empty scratch folder, never in a project.
        let cwd = try #require(call.currentDirectory)
        #expect(cwd.contains("SweepInsights"))
    }

    @Test func fallsBackToResultTextWhenNoStructuredOutput() async throws {
        let runner = FakeCommandRunner(fallback: CommandResult(exitCode: 0, stdout: envelope(structured: nil, result: answer), stderr: ""))
        let raw = try await ClaudeCodeProvider(executable: "/x/claude", runner: runner).complete(system: "s", user: "u")
        #expect(raw.contains("Caches regrew"))
    }

    @Test func reportsClaudeCodeErrors() async {
        let runner = FakeCommandRunner(fallback: CommandResult(exitCode: 1, stdout: envelope(structured: nil, result: "Invalid API key · Please run /login", isError: true), stderr: ""))
        await #expect(throws: InsightsError.claudeCode("Invalid API key · Please run /login")) {
            try await ClaudeCodeProvider(executable: "/x/claude", runner: runner).complete(system: "s", user: "u")
        }
    }

    @Test func reportsCrashWithStderr() async {
        let runner = FakeCommandRunner(fallback: CommandResult(exitCode: 2, stdout: "", stderr: "boom"))
        await #expect(throws: InsightsError.claudeCode("exit 2: boom")) {
            try await ClaudeCodeProvider(executable: "/x/claude", runner: runner).complete(system: "s", user: "u")
        }
    }

    @Test func reportsTimeout() async {
        let runner = FakeCommandRunner(fallback: CommandResult(exitCode: -9, stdout: "", stderr: "", timedOut: true))
        await #expect(throws: InsightsError.claudeCode("timed out")) {
            try await ClaudeCodeProvider(executable: "/x/claude", runner: runner).complete(system: "s", user: "u")
        }
    }

    @Test func locatesClaudeInUsualPlaces() {
        #expect(ClaudeCodeProvider.locate(tools: FakeToolLocator(["claude"]), home: "/nonexistent") == "/opt/homebrew/bin/claude")
        #expect(ClaudeCodeProvider.locate(tools: FakeToolLocator([]), home: "/nonexistent") == nil)
        #expect(ClaudeCodeProvider.candidatePaths(home: "/Users/me").contains("/Users/me/.claude/local/claude"))
        #expect(ClaudeCodeProvider.candidatePaths(home: "/Users/me").contains("/Users/me/.local/bin/claude"))
    }
}

@Suite struct InsightsProviderSetupTests {
    @Test func ollamaTagsParse() throws {
        let json = #"{"models":[{"name":"llama3.1:8b","size":4900000000},{"name":"qwen3:14b","size":9000000000}]}"#
        #expect(try OllamaProvider.parseTags(Data(json.utf8)) == ["llama3.1:8b", "qwen3:14b"])
    }

    @Test func providerKindKeepsOldAPISetting() {
        #expect(InsightsProviderKind(rawValue: "claude") == .anthropicAPI)   // value saved by 0.1.0
        #expect(InsightsProviderKind.default == .claudeCode)
        #expect(InsightsProviderKind(cliName: "claude-code") == .claudeCode)
        #expect(InsightsProviderKind(cliName: "ollama") == .ollama)
        #expect(InsightsProviderKind(cliName: "anthropic") == .anthropicAPI)
    }

    @Test func onlyOllamaStaysOnTheMac() {
        #expect(InsightsProviderKind.ollama.isLocal)
        #expect(!InsightsProviderKind.claudeCode.isLocal)
        #expect(!InsightsProviderKind.anthropicAPI.isLocal)
    }
}

@Suite struct SchemaConstraintTests {
    @Test func schemaLimitsItemIDsToTheScan() throws {
        let s = InsightsContract.jsonSchema(knownIDs: ["b2", "a1"])
        let props = try #require(s["properties"] as? [String: Any])
        let rec = try #require(((props["recommendations"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])
        let recIDs = try #require((rec["itemIds"] as? [String: Any])?["items"] as? [String: Any])
        #expect(recIDs["enum"] as? [String] == ["a1", "b2"])
        let ins = try #require(((props["insights"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any])
        let insIDs = try #require((ins["evidenceItemIds"] as? [String: Any])?["items"] as? [String: Any])
        #expect(insIDs["enum"] as? [String] == ["a1", "b2"])
    }

    @Test func noKnownIDsMeansNoEnum() throws {
        let s = InsightsContract.jsonSchema(knownIDs: [])
        let data = try JSONSerialization.data(withJSONObject: s)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"enum\":[]"))
    }

    @Test func serviceSendsTheConstrainedSchema() async throws {
        final class Capture: InsightsProvider, @unchecked Sendable {
            var schema: [String: Any] = [:]
            func complete(system: String, user: String, schema: [String: Any]) async throws -> String {
                self.schema = schema
                return #"{"headline":"h","insights":[],"recommendations":[],"maintenanceSuggestions":[],"questionsForUser":[]}"#
            }
        }
        let cap = Capture()
        let summary = InsightsSummary(totalBytes: 1, freeBytes: 1, unaccountedBytes: 0, fullDiskAccess: true, buckets: [], items: [
            .init(id: "x1", category: "c", title: "t", path: "p", physicalBytes: 1, tier: 1, rebuildCost: "low", actionable: true,
                  lastUsedDaysAgo: nil, growthPerDay: nil, evidence: [])],
            rootCauses: [], priorDecisions: [:])
        _ = await InsightsService.run(summary: summary, provider: cap)
        let data = try JSONSerialization.data(withJSONObject: cap.schema)
        #expect(String(decoding: data, as: UTF8.self).contains("\"x1\""))
    }
}
