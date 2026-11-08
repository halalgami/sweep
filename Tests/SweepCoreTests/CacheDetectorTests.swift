import Foundation
import Testing
@testable import SweepCore

@Suite struct CacheDetectorTests {
    @Test func uvCacheUsesToolPruneAndMeasuresDir() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/.cache/uv/wheels/a.whl", logical: 5_000_000_000)
        let runner = FakeCommandRunner()
        runner.stub("/opt/homebrew/bin/uv cache dir", stdout: "/Users/me/.cache/uv\n")
        let ctx = makeContext(probe: fs, runner: runner, tools: ["uv"])
        let out = await DetectorRegistry.detector(for: .toolCache).detect(rule: rule("cache.uv"), context: ctx)
        let item = try! #require(out.items.first)
        #expect(item.physicalBytes == 5_000_000_000)
        #expect(item.action == .toolCommand(executable: "/opt/homebrew/bin/uv", arguments: ["cache", "prune"]))
        #expect(item.tier == .safe)
        #expect(item.routine)
    }

    @Test func missingToolYieldsWarningNotItem() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/.cache/uv/x", logical: 10_000_000)
        let out = await DetectorRegistry.detector(for: .toolCache).detect(rule: rule("cache.uv"), context: makeContext(probe: fs))
        #expect(out.items.isEmpty)
        #expect(out.warnings.first?.contains("uv isn't installed") == true)
    }

    @Test func npxBlockedWhileNpmExecRuns() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/.npm/_npx/abc/pkg.tgz", logical: 20_000_000)
        let ctx = makeContext(probe: fs, processes: [
            RunningProcess(pid: 42, ppid: 1, command: "node", arguments: ["node", "/opt/homebrew/bin/npm", "exec", "foo"], cwd: nil)])
        let out = await DetectorRegistry.detector(for: .pathCache).detect(rule: rule("cache.npx"), context: ctx)
        let item = try! #require(out.items.first)
        guard case let .none(reason) = item.action else { Issue.record("expected .none"); return }
        #expect(reason.contains("running"))
    }

    @Test func libraryCachesSplitPerAppAndCountProtected() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/Library/Caches/com.big.app/blob", logical: 200_000_000)
        fs.addFile("/Users/me/Library/Caches/com.tiny.app/blob", logical: 1_000)
        fs.addFile("/Users/me/Library/Caches/com.microsoft.VSCode.ShipIt/update.zip", logical: 300_000_000)
        fs.addDir("/Users/me/Library/Caches/com.apple.locked", unreadable: true)
        let out = await DetectorRegistry.detector(for: .libraryCaches).detect(rule: rule("cache.library"), context: makeContext(probe: fs))
        #expect(out.items.count == 2)
        let shipit = out.items.first { $0.path.hasSuffix("ShipIt") }
        #expect(shipit?.evidence.contains { $0.contains("staged app update") } == true)
        #expect(out.warnings.contains { $0.contains("1 Apple-protected") })
    }

    @Test func editorExtensionsKeepNewestOnly() async {
        let fs = FakeFileSystemProbe()
        let base = "/Users/me/.vscode/extensions"
        fs.addFile("\(base)/ms-python.python-2024.1.0/a", logical: 50_000_000, mtime: Date(timeIntervalSince1970: 1_000))
        fs.addDir("\(base)/ms-python.python-2024.1.0", mtime: Date(timeIntervalSince1970: 1_000))
        fs.addFile("\(base)/ms-python.python-2025.2.0/a", logical: 50_000_000)
        fs.addDir("\(base)/ms-python.python-2025.2.0", mtime: Date(timeIntervalSince1970: 2_000))
        fs.addDir("\(base)/esbenp.prettier-vscode-10.1.0", mtime: Date(timeIntervalSince1970: 1_500))
        let out = await DetectorRegistry.detector(for: .vscodeExtensions).detect(rule: rule("editor.vscode-extensions"), context: makeContext(probe: fs))
        #expect(out.items.map(\.path) == ["\(base)/ms-python.python-2024.1.0"])
        #expect(out.items.first?.action == .hardDelete)
    }

    @Test func editorExtensionsBlockedWhileEditorRuns() async {
        let fs = FakeFileSystemProbe()
        let base = "/Users/me/.vscode/extensions"
        fs.addDir("\(base)/a.b-1.0.0", mtime: Date(timeIntervalSince1970: 1_000))
        fs.addFile("\(base)/a.b-1.0.0/x", logical: 5_000_000)
        fs.addDir("\(base)/a.b-2.0.0", mtime: Date(timeIntervalSince1970: 2_000))
        let ctx = makeContext(probe: fs, processes: [RunningProcess(pid: 9, ppid: 1, command: "Electron",
            arguments: ["/Applications/Visual Studio Code.app/Contents/MacOS/Electron"], cwd: nil)])
        let out = await DetectorRegistry.detector(for: .vscodeExtensions).detect(rule: rule("editor.vscode-extensions"), context: ctx)
        guard case let .none(reason)? = out.items.first?.action else { Issue.record("expected blocked"); return }
        #expect(reason == "Quit Visual Studio Code first")
    }

    @Test func dockerBuildersPrunedByNameNotContainerName() async {
        let runner = FakeCommandRunner()
        let d = "/opt/homebrew/bin/docker"
        runner.stub("\(d) info --format {{.ServerVersion}}", stdout: "27.0.1\n")
        runner.stub("\(d) buildx ls --format {{.Name}}", stdout: "default\ncolima*\ncolima\n")
        runner.stub("\(d) buildx du --builder default", stdout: "ID RECLAIMABLE SIZE\nabc true 1.2GB\nReclaimable:\t1.2GB\nTotal:\t1.5GB\n")
        runner.stub("\(d) buildx du --builder colima", stdout: "Reclaimable:\t300MB\nTotal:\t300MB\n")
        let out = await DetectorRegistry.detector(for: .docker).detect(rule: rule("docker.builder"), context: makeContext(runner: runner, tools: ["docker"]))
        #expect(out.items.map(\.action) == [
            .dockerCommand(arguments: ["buildx", "prune", "-f", "--builder", "default"]),
            .dockerCommand(arguments: ["buildx", "prune", "-f", "--builder", "colima"])])
        #expect(out.items.map(\.physicalBytes) == [1_200_000_000, 300_000_000])
        #expect(!runner.calls.contains { $0.contains("buildx_buildkit") })
    }

    @Test func dockerNotRunningSkipsWithWarning() async {
        let runner = FakeCommandRunner()
        let out = await DetectorRegistry.detector(for: .docker).detect(rule: rule("docker.builder"), context: makeContext(runner: runner, tools: ["docker"]))
        #expect(out.items.isEmpty)
        #expect(out.warnings.first?.contains("Docker isn't running") == true)
    }

    @Test func unusedDockerImagesExcludeInUseAndDangling() async {
        let runner = FakeCommandRunner()
        let d = "/opt/homebrew/bin/docker"
        runner.stub("\(d) info --format {{.ServerVersion}}", stdout: "27\n")
        runner.stub("\(d) images --format {{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}",
                    stdout: "aaa\tpostgres:16\t400MB\nbbb\tredis:7\t120MB\nccc\t<none>:<none>\t50MB\n")
        runner.stub("\(d) ps -a --format {{.Image}}", stdout: "postgres:16\n")
        let out = await DetectorRegistry.detector(for: .docker).detect(rule: rule("docker.images"), context: makeContext(runner: runner, tools: ["docker"]))
        #expect(out.items.map(\.title) == ["Docker image redis:7"])
        #expect(out.items.first?.action == .dockerCommand(arguments: ["image", "rm", "redis:7"]))
        #expect(out.items.first?.tier == .needsDecision)
    }

    @Test func dockerSizesParse() {
        #expect(DockerDetector.parseSize("1.2GB") == 1_200_000_000)
        #expect(DockerDetector.parseSize("512kB") == 512_000)
        #expect(DockerDetector.parseSize("0B") == 0)
        #expect(DockerDetector.parseSize("garbage") == 0)
    }

    @Test func protectedClonePathsAreTier4() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/private/var/folders/ab/cd/X/com.google.Chrome.code_sign_clone/blob", logical: 900_000_000)
        let out = await DetectorRegistry.detector(for: .protectedPaths).detect(rule: rule("protected.paths"), context: makeContext(probe: fs))
        let item = try! #require(out.items.first)
        #expect(item.tier == .protected)
        guard case let .none(reason) = item.action else { Issue.record("expected none"); return }
        #expect(reason.contains("won't free space"))
    }

    @Test func readOnlyParentFallsBackToReveal() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/usr/local/texlive/2024/bin/tex", logical: 6_000_000_000)
        let out = await DetectorRegistry.detector(for: .texlive).detect(rule: rule("decision.texlive"),
            context: makeContext(probe: fs))
        #expect(out.items.first?.action == .revealInFinder)
    }
}
