import Darwin
import Foundation
import Testing
@testable import SweepCore

/// Regression tests for the minor findings deferred from the first review.
@Suite struct MinorFixTests {
    let docker = "/opt/homebrew/bin/docker"

    // M1a: `docker system df` prints "1.2GB (50%)" in the Reclaimable column.
    @Test func dockerSizeWithPercentSuffixParses() {
        #expect(DockerDetector.parseSize("1.2GB (50%)") == 1_200_000_000)
        #expect(DockerDetector.parseSize("0B (0%)") == 0)
    }

    @Test func classicBuilderCacheMeasuredFromSystemDF() async {
        let runner = FakeCommandRunner()
        runner.stub("\(docker) info --format {{.ServerVersion}}", stdout: "27\n")
        runner.stub("\(docker) context inspect --format {{.Endpoints.docker.Host}}", stdout: "unix:///var/run/docker.sock\n")
        runner.stub("\(docker) system df --format {{.Type}}\t{{.Reclaimable}}",
                    stdout: "Images\t2GB (40%)\nContainers\t0B (0%)\nLocal Volumes\t1GB (100%)\nBuild Cache\t3.5GB (100%)\n")
        let out = await DetectorRegistry.detector(for: .docker).detect(rule: rule("docker.builder"), context: makeContext(runner: runner, tools: ["docker"]))
        #expect(out.items.map(\.physicalBytes) == [3_500_000_000])
    }

    // M1b: an image with several tags can't be removed by ID; remove it by its tags, one item per image.
    @Test func multiTagImageIsOneItemRemovedByTags() async {
        let runner = FakeCommandRunner()
        runner.stub("\(docker) info --format {{.ServerVersion}}", stdout: "27\n")
        runner.stub("\(docker) context inspect --format {{.Endpoints.docker.Host}}", stdout: "unix:///var/run/docker.sock\n")
        runner.stub("\(docker) images --format {{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}",
                    stdout: "bbb\tredis:7\t120MB\nbbb\tmyrepo/redis:prod\t120MB\n")
        runner.stub("\(docker) ps -a --format {{.Image}}", stdout: "")
        let out = await DetectorRegistry.detector(for: .docker).detect(rule: rule("docker.images"), context: makeContext(runner: runner, tools: ["docker"]))
        #expect(out.items.count == 1)
        #expect(out.items.first?.physicalBytes == 120_000_000)
        #expect(out.items.first?.action == .dockerCommand(arguments: ["image", "rm", "redis:7", "myrepo/redis:prod"]))
        #expect(out.items.first?.title == "Docker image redis:7 (+1 more tag)")
    }

    @Test func imageRemovalByTagIsAllowlisted() async {
        let local = FakeCommandRunner()
        local.stub("\(docker) context inspect --format {{.Endpoints.docker.Host}}", stdout: "unix:///var/run/docker.sock\n")
        let g = SafetyGuard(context: makeContext(runner: local, tools: ["docker"]), rules: guardRules,
                            protected: ProtectedLocations(home: "/Users/me", userProtected: [], iCloudDesktopAndDocuments: false))
        #expect(await g.check(testItem("docker://image/bbb", action: .dockerCommand(arguments: ["image", "rm", "redis:7", "myrepo/redis:prod"]))) == .allowed)
        #expect(await g.check(testItem("docker://image/bbb", action: .dockerCommand(arguments: ["image", "rm", "-f", "redis:7"]))) != .allowed)
    }

    // M2: a folder that vanished before deletion isn't "removed (0)".
    @Test func vanishedFolderIsReportedAlreadyGone() async throws {
        let t = TempDir()
        let ex = executor(home: t.path, log: t.url.appendingPathComponent("l"))
        let r = await ex.run(testItem(t.path + "/Library/Caches/gone"), log: { _ in })
        #expect(r.status == .alreadyGone)
        #expect(r.removedPaths == 0)
        #expect(Verifier.verification(before: vol(0), after: vol(0), results: [r]).expectedBytes == 0)
    }

    // M3: a partly removed item only counts what was actually removed.
    @Test func partialResultCountsOnlyRemovedBytes() async throws {
        let t = TempDir()
        t.file("Library/Caches/c/a.bin", bytes: 64 * 1024)
        let locked = t.file("Library/Caches/c/locked.bin", bytes: 64 * 1024)
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked, 0) }
        let ex = executor(home: t.path, log: t.url.appendingPathComponent("l"))
        let r = await ex.run(testItem(t.path + "/Library/Caches/c", bytes: 128 * 1024), log: { _ in })
        #expect(r.status == .partial)
        #expect(r.expectedBytes >= 64 * 1024)
        #expect(r.expectedBytes < 128 * 1024)
    }

    // M5: a path equal to a sensitive root plus "/" used to crash the redactor.
    @Test func redactorHandlesRootWithTrailingSlash() {
        let r = Redactor(home: "/Users/me", sensitiveRoots: ["/Users/me/Documents"], revealNames: false)
        #expect(r.redact(path: "/Users/me/Documents/") == "~/Documents")
        #expect(r.redact(path: "/Users/me/Documents//x") == "~/Documents/project_01")
    }

    // M6: at most 6 insights; risk must be low/medium/high.
    @Test func moreThanSixInsightsRejected() {
        let ins = Array(repeating: #"{"title":"t","detail":"d","evidenceItemIds":[]}"#, count: 7).joined(separator: ",")
        let raw = #"{"headline":"h","insights":[\#(ins)],"recommendations":[],"maintenanceSuggestions":[],"questionsForUser":[]}"#
        guard case .failure(.schema) = InsightsContract.validate(raw, knownIDs: []) else { Issue.record("expected schema failure"); return }
    }

    @Test func unknownRiskRejected() {
        let raw = #"{"headline":"h","insights":[],"recommendations":[{"itemIds":[],"action":"a","expectedBytes":0,"risk":"yolo","why":"w"}],"maintenanceSuggestions":[],"questionsForUser":[]}"#
        guard case .failure(.schema) = InsightsContract.validate(raw, knownIDs: []) else { Issue.record("expected schema failure"); return }
    }

    // M7: after a downgrade the newest-by-date folder isn't the installed one; trust extensions.json, else the highest version.
    @Test func editorExtensionsTrustExtensionsJSON() async throws {
        let t = TempDir()
        let base = t.dir(".vscode/extensions")
        t.file(".vscode/extensions/ms-python.python-2025.2.0/a", bytes: 10, mtime: Date(timeIntervalSince1970: 1_000))
        t.file(".vscode/extensions/ms-python.python-2024.1.0/a", bytes: 10, mtime: Date(timeIntervalSince1970: 2_000))
        try #"[{"identifier":{"id":"ms-python.python"},"version":"2025.2.0","relativeLocation":"ms-python.python-2025.2.0"}]"#
            .write(toFile: base + "/extensions.json", atomically: true, encoding: .utf8)
        // Downgrade: the older version is the one in use, even though the other folder is newer on disk.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: base + "/ms-python.python-2024.1.0")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: base + "/ms-python.python-2025.2.0")
        var ctx = makeContext(); ctx.home = t.path; ctx.probe = RealFileSystemProbe()
        let out = await DetectorRegistry.detector(for: .vscodeExtensions).detect(rule: rule("editor.vscode-extensions"), context: ctx)
        #expect(out.items.map { ($0.path as NSString).lastPathComponent } == ["ms-python.python-2024.1.0"])

        try #"[{"identifier":{"id":"ms-python.python"},"version":"2024.1.0","relativeLocation":"ms-python.python-2024.1.0"}]"#
            .write(toFile: base + "/extensions.json", atomically: true, encoding: .utf8)
        let out2 = await DetectorRegistry.detector(for: .vscodeExtensions).detect(rule: rule("editor.vscode-extensions"), context: ctx)
        #expect(out2.items.map { ($0.path as NSString).lastPathComponent } == ["ms-python.python-2025.2.0"])
    }

    @Test func editorExtensionsWithoutManifestKeepHighestVersion() async {
        let fs = FakeFileSystemProbe()
        let base = "/Users/me/.vscode/extensions"
        fs.addDir("\(base)/ms-python.python-2025.10.0", mtime: Date(timeIntervalSince1970: 1_000))
        fs.addDir("\(base)/ms-python.python-2025.9.0", mtime: Date(timeIntervalSince1970: 2_000))
        let out = await DetectorRegistry.detector(for: .vscodeExtensions).detect(rule: rule("editor.vscode-extensions"), context: makeContext(probe: fs))
        #expect(out.items.map(\.path) == ["\(base)/ms-python.python-2025.9.0"])
    }

    // M8: helpers started by launchd also have ppid 1; only flag ones whose process group leader (the agent) is gone.
    @Test func launchdServicesAreNotOrphans() {
        let ctx = makeContext(processes: [
            RunningProcess(pid: 79, ppid: 1, pgid: 79, command: "node", arguments: ["node", "/x/npx", "@modelcontextprotocol/server-launchd"], cwd: nil),
            RunningProcess(pid: 77, ppid: 1, pgid: 70, command: "node", arguments: ["node", "/x/npx", "@modelcontextprotocol/server-github"], cwd: nil),
        ])
        let detail = RootCauseAnalyzer().analyze(context: ctx).filter { $0.kind == "orphanMCP" }.map(\.detail).joined()
        #expect(detail.contains("77"))
        #expect(!detail.contains("79"))
    }

    @Test func groupLeaderStillAliveMeansNotOrphan() {
        let ctx = makeContext(processes: [
            RunningProcess(pid: 70, ppid: 500, pgid: 70, command: "claude", arguments: ["claude"], cwd: nil),
            RunningProcess(pid: 77, ppid: 1, pgid: 70, command: "node", arguments: ["node", "/x/npx", "@modelcontextprotocol/server-github"], cwd: nil),
        ])
        #expect(!RootCauseAnalyzer().analyze(context: ctx).contains { $0.kind == "orphanMCP" })
    }

    // M10: all of /usr is off limits except /usr/local.
    @Test func usrIsNeverTouchedExceptUsrLocal() {
        let p = ProtectedLocations(home: "/Users/me", userProtected: [], iCloudDesktopAndDocuments: false)
        #expect(p.reason(for: "/usr/share/man") != nil)
        #expect(p.reason(for: "/usr/libexec/x") != nil)
        #expect(p.reason(for: "/usr/local/texlive/2023") == nil)
        #expect(p.reason(for: "/Library/Apple/x") != nil)
    }

    // M11: errors carry their own type, not SQLiteError.
    @Test func launchctlFailureIsAMaintenanceError() async {
        let runner = FakeCommandRunner(fallback: CommandResult(exitCode: 5, stdout: "", stderr: "Bootstrap failed: 5"))
        let t = TempDir()
        let mgr = LaunchAgentManager(home: t.path, runner: runner)
        await #expect(throws: MaintenanceError.self) { try await mgr.install(agentPath: "/Applications/Sweep.app/Contents/MacOS/SweepAgent") }
    }

    // M12: deleting a big tree doesn't run on the cooperative pool.
    @Test func deleteTreeRunsOffTheCooperativePool() async {
        let t = TempDir()
        t.file("x/a", bytes: 10)
        let r = await Executor.deleteTreeAsync(t.path + "/x")
        #expect(r.removed == 1)
        #expect(!FileManager.default.fileExists(atPath: t.path + "/x"))
    }

    // M13: the first Automation prompt can take longer than the timeout; say we're waiting, not that the Trash is unreadable.
    @Test func trashTimeoutSaysWaitingForPermission() async {
        let runner = FakeCommandRunner(fallback: CommandResult(exitCode: -9, stdout: "", stderr: "", timedOut: true))
        let out = await DetectorRegistry.detector(for: .leftovers).detect(rule: rule("leftovers.trash"), context: makeContext(runner: runner, tools: ["osascript"]))
        #expect(out.warnings.first?.contains("waiting for you to allow") == true)
    }

    @Test func trashPermissionDeniedSaysSo() async {
        let runner = FakeCommandRunner(fallback: CommandResult(exitCode: 1, stdout: "", stderr: "execution error: Not authorized to send Apple events to Finder. (-1743)"))
        let out = await DetectorRegistry.detector(for: .leftovers).detect(rule: rule("leftovers.trash"), context: makeContext(runner: runner, tools: ["osascript"]))
        #expect(out.warnings.first?.contains("Automation") == true)
    }

    // helpers
    func vol(_ free: Int64) -> VolumeSummary { VolumeSummary(totalBytes: 1000, availableBytes: free, importantAvailableBytes: free, usedBytes: 1000 - free) }
    func executor(home: String, log: URL) -> Executor {
        var ctx = makeContext(tools: ["git"])
        ctx.home = home; ctx.probe = RealFileSystemProbe(); ctx.runner = ProcessCommandRunner()
        let guardian = SafetyGuard(context: ctx, rules: guardRules, protected: ProtectedLocations(home: home, userProtected: [], iCloudDesktopAndDocuments: false))
        return Executor(guardian: guardian, context: ctx, logURL: log)
    }
}
