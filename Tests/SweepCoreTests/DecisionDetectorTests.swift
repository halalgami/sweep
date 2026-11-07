import Foundation
import Testing
@testable import SweepCore

@Suite struct DecisionDetectorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86400) }

    @Test func simRuntimesUseSimctlSizes() async throws {
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/xcrun simctl runtime list -j", stdout: String(decoding: try fixture("simctl_runtimes.json"), as: UTF8.self))
        let out = await DetectorRegistry.detector(for: .simRuntimes).detect(rule: rule("decision.simruntimes"),
                                                                        context: makeContext(runner: runner, tools: ["xcrun"], now: now))
        #expect(out.items.count == 2)
        let ios = try #require(out.items.first { $0.title.contains("iOS") })
        #expect(ios.physicalBytes > 1_000_000_000)
        guard case let .toolCommand(exe, args) = ios.action else { Issue.record("expected tool"); return }
        #expect(exe == "/usr/bin/xcrun")
        #expect(args.prefix(3) == ["simctl", "runtime", "delete"])
    }

    @Test func lsregisterRecordsPairFieldsWithinRecordOnly() throws {
        let recs = LSRegisterParser.records(String(decoding: try fixture("lsregister_dump.txt"), as: UTF8.self))
        #expect(recs.contains { $0.path == "/Applications/The Witcher 3.app" && $0.identifier == "com.gog.witcher3" })
        #expect(recs.contains { $0.path == "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper (GPU).app" })
        #expect(!recs.contains { $0.path == "/Applications/NoIdentifier.app" })     // no identifier → dropped, not cross-paired
        #expect(!recs.contains { $0.identifier == "com.gog.witcher3" && $0.path.contains("NoIdentifier") })
    }

    func leftoversContext(fs: FakeFileSystemProbe, extraTools: [String] = []) throws -> DetectionContext {
        let runner = FakeCommandRunner()
        runner.stub((["/usr/bin/osascript"] + LeftoversDetector.trashScriptArguments).joined(separator: " "),
                    stdout: "/Users/me/.Trash/GOG Galaxy.app/\n/Users/me/.Trash/Notely.app/\n/Users/me/.Trash/photo.jpg\n")
        runner.stub(LeftoversDetector.lsregister + " -dump", stdout: String(decoding: try fixture("lsregister_dump.txt"), as: UTF8.self))
        runner.stub("/usr/sbin/pkgutil --pkgs", stdout: "com.apple.pkg.Core\nio.notely.app.pkg\n")
        return makeContext(probe: fs, runner: runner, tools: ["osascript"] + extraTools, now: now)
    }

    @Test func leftoversFoundByBundleIDAndName() async throws {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/Library/Application Support/Notely/db.sqlite", logical: 40_000_000)
        fs.addFile("/Users/me/Library/Preferences/io.notely.app.plist", logical: 4_096)
        fs.addFile("/Users/me/Library/Containers/io.notely.app/Data/x", logical: 10_000_000)
        fs.addFile("/Users/me/Library/Caches/com.other.app/x", logical: 10_000_000)
        let out = await DetectorRegistry.detector(for: .leftovers).detect(rule: rule("leftovers.trash"), context: try leftoversContext(fs: fs))
        let paths = Set(out.items.map(\.path))
        #expect(paths.contains("/Users/me/Library/Application Support/Notely"))
        #expect(paths.contains("/Users/me/Library/Preferences/io.notely.app.plist"))
        #expect(!paths.contains { $0.contains("com.other.app") })
        let container = try #require(out.items.first { $0.path.hasSuffix("Containers/io.notely.app") })
        #expect(container.action == .revealInFinder)
        #expect(container.evidence.contains { $0.contains("Finder") })
        let receipt = try #require(out.items.first { $0.path == "pkgutil://io.notely.app.pkg" })
        guard case let .none(reason) = receipt.action else { Issue.record("receipt must not be actionable"); return }
        #expect(reason.contains("sudo pkgutil --forget io.notely.app.pkg"))
    }

    @Test func sharedVendorItemsKeptWhenSiblingInstalled() async throws {
        let fs = FakeFileSystemProbe()
        fs.addDir("/Applications/The Witcher 3.app")
        fs.addFile("/Users/me/Library/Application Support/GOG Galaxy/storage/x", logical: 30_000_000)
        fs.addFile("/Users/me/Library/Preferences/com.gog.galaxy.plist", logical: 4_096)
        let out = await DetectorRegistry.detector(for: .leftovers).detect(rule: rule("leftovers.trash"), context: try leftoversContext(fs: fs))
        let paths = out.items.map(\.path)
        #expect(paths.contains("/Users/me/Library/Preferences/com.gog.galaxy.plist"))       // exact id still offered
        #expect(!paths.contains("/Users/me/Library/Application Support/GOG Galaxy"))      // name-only + vendor sibling → kept
    }

    @Test func staleRecordForDeletedSiblingDoesNotBlock() async throws {
        let fs = FakeFileSystemProbe()   // Witcher's lsregister record exists but the app is gone
        fs.addFile("/Users/me/Library/Application Support/GOG Galaxy/storage/x", logical: 30_000_000)
        let out = await DetectorRegistry.detector(for: .leftovers).detect(rule: rule("leftovers.trash"), context: try leftoversContext(fs: fs))
        #expect(out.items.map(\.path).contains("/Users/me/Library/Application Support/GOG Galaxy"))
    }

    @Test func recentlyUsedCliDotdirIsNotPreselected() async throws {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/.config/notely/config.toml", logical: 2_000_000, mtime: daysAgo(2))
        fs.addDir("/Users/me/.config/notely", mtime: daysAgo(2))
        let out = await DetectorRegistry.detector(for: .leftovers).detect(rule: rule("leftovers.trash"), context: try leftoversContext(fs: fs))
        let item = try #require(out.items.first { $0.path == "/Users/me/.config/notely" })
        #expect(!item.defaultSelected)
        #expect(item.evidence.contains { $0.contains("recently") })
    }

    @Test func sensitiveDataFlaggedAndNeverActionable() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/Projects/crm/package.json", logical: 1)
        fs.addFile("/Users/me/Projects/crm/exports/customers.csv", logical: 80_000_000)
        fs.addFile("/Users/me/Projects/crm/node_modules/pkg/data.json", logical: 90_000_000)
        fs.addFile("/Users/me/Projects/crm/small.csv", logical: 1_000)
        let out = await DetectorRegistry.detector(for: .sensitiveData).detect(rule: rule("decision.sensitive-data"), context: makeContext(probe: fs, now: now))
        #expect(out.items.map(\.path) == ["/Users/me/Projects/crm/exports/customers.csv"])
        #expect(out.items.first?.sensitive == true)
        #expect(out.items.first?.action == .revealInFinder)
        #expect(out.items.first?.defaultSelected == false)
    }

    @Test func largeFilesSkipCloudPlaceholders() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/Downloads/movie.mkv", logical: 3_000_000_000)
        fs.addFile("/Users/me/Documents/cloud.mov", logical: 5_000_000_000, flags: FileMeta.datalessFlag)
        fs.addFile("/Users/me/Documents/small.pdf", logical: 5_000_000)
        let out = await DetectorRegistry.detector(for: .largeFiles).detect(rule: rule("decision.large-files"), context: makeContext(probe: fs, now: now))
        #expect(out.items.map(\.path) == ["/Users/me/Downloads/movie.mkv"])
        #expect(out.items.first?.action == .trash)
    }

    @Test func oldInstallersOnly() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/Downloads/Old.dmg", logical: 200_000_000, mtime: daysAgo(90))
        fs.addFile("/Users/me/Downloads/New.pkg", logical: 200_000_000, mtime: daysAgo(3))
        fs.addFile("/Users/me/Downloads/notes.txt", logical: 200_000_000, mtime: daysAgo(90))
        let out = await DetectorRegistry.detector(for: .installers).detect(rule: rule("decision.installers"), context: makeContext(probe: fs, now: now))
        #expect(out.items.map(\.path) == ["/Users/me/Downloads/Old.dmg"])
    }

    @Test func deviceSupportKeepsNewestTwo() async {
        let fs = FakeFileSystemProbe()
        let base = "/Users/me/Library/Developer/Xcode/iOS DeviceSupport"
        for (i, v) in ["16.4 (20E247)", "17.5 (21F79)", "18.1 (22B83)", "26.0 (23A341)"].enumerated() {
            fs.addFile("\(base)/\(v)/Symbols/x", logical: 3_000_000_000)
            fs.addDir("\(base)/\(v)", mtime: daysAgo(Double(400 - i * 100)))
        }
        let out = await DetectorRegistry.detector(for: .xcodeOldDerivedData).detect(rule: rule("decision.xcode-old-deriveddata"), context: makeContext(probe: fs, now: now))
        #expect(Set(out.items.map { ($0.path as NSString).lastPathComponent }) == ["16.4 (20E247)", "17.5 (21F79)"])
    }

    @Test func vmShowsLastBooted() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/Parallels/Windows 11.pvm/disk.hdd", logical: 57_000_000_000)
        fs.addFile("/Users/me/Parallels/Windows 11.pvm/parallels.log", logical: 1_000, mtime: daysAgo(31))
        let out = await DetectorRegistry.detector(for: .vms).detect(rule: rule("decision.vms"), context: makeContext(probe: fs, now: now))
        let item = out.items.first
        #expect(item?.title == "Windows 11 (VM)")
        #expect(item?.evidence.contains("Last booted 31 days ago") == true)
        #expect(item?.action == .trash)
    }

    @Test func ollamaModelsListedWithRemoveCommand() async {
        let runner = FakeCommandRunner()
        runner.stub("/opt/homebrew/bin/ollama list", stdout: "NAME            ID              SIZE      MODIFIED\nllama3:8b       365c0bd3c000    4.7 GB    3 weeks ago\nqwen2:0.5b      6f48b936a09f    352 MB    2 days ago\n")
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/.ollama/models/blobs/sha256-a", logical: 4_700_000_000)
        let out = await DetectorRegistry.detector(for: .llmModels).detect(rule: rule("decision.llm-models"),
                                                                      context: makeContext(probe: fs, runner: runner, tools: ["ollama"], now: now))
        let llama = out.items.first { $0.title.contains("llama3:8b") }
        #expect(llama?.physicalBytes == 4_700_000_000)
        #expect(llama?.action == .toolCommand(executable: "/opt/homebrew/bin/ollama", arguments: ["rm", "llama3:8b"]))
    }
}
