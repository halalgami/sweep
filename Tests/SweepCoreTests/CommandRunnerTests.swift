import Foundation
import Testing
@testable import SweepCore

@Suite struct CommandRunnerTests {
    let runner = ProcessCommandRunner()

    @Test func capturesStdout() async {
        let r = await runner.run("/bin/echo", ["hi"], timeout: 5)
        #expect(r.ok)
        #expect(r.stdout == "hi\n")
    }

    @Test func timesOutHangingProcess() async {
        let start = Date()
        let r = await runner.run("/bin/sleep", ["5"], timeout: 0.3)
        #expect(r.timedOut)
        #expect(!r.ok)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func missingExecutableReports127() async {
        let r = await runner.run("/nonexistent/tool", [], timeout: 2)
        #expect(r.exitCode == 127)
        #expect(!r.ok)
    }

    @Test func capturesLargeOutputCompletely() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID()).txt")
        let line = String(repeating: "x", count: 1023) + "\n"
        try String(repeating: line, count: 2048).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = await runner.run("/bin/cat", [url.path], timeout: 10)
        #expect(r.ok)
        #expect(r.stdout.utf8.count == 2048 * 1024)
    }

    @Test func capturesStderrAndExitCode() async {
        let r = await runner.run("/bin/ls", ["/definitely/not/here"], timeout: 5)
        #expect(!r.ok)
        #expect(r.stderr.contains("No such file"))
    }

    @Test func toolLocatorFindsLs() {
        #expect(ToolLocator(searchPaths: ["/nope", "/bin"]).path(for: "ls") == "/bin/ls")
        #expect(ToolLocator(searchPaths: ["/bin"]).path(for: "definitely-not-a-tool") == nil)
    }

    @Test func processListingIncludesSelf() {
        let me = getpid()
        let procs = SystemProcessListing().processes()
        let mine = procs.first { $0.pid == me }
        #expect(mine != nil)
        #expect(!(mine?.arguments.isEmpty ?? true))
    }

    @Test func processMatchingUsesArguments() {
        let listing = StaticProcessListing([
            RunningProcess(pid: 10, ppid: 1, command: "node", arguments: ["node", "/x/next", "dev"], cwd: "/p"),
            RunningProcess(pid: 11, ppid: 1, command: "uv", arguments: ["uv", "run", "x"], cwd: nil),
        ])
        #expect(listing.matching("uvx|uv run").map(\.pid) == [11])
        #expect(listing.matching("next dev|next\\s+dev|/next dev|next.* dev").map(\.pid) == [10])
    }
}
