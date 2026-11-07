import Foundation

/// Support files left by apps currently in the Trash.
struct LeftoversDetector: Detector {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let pkgutil = "/usr/sbin/pkgutil"
    /// Finder AppleScript (Terminal-launched tools can't list ~/.Trash without Full Disk Access).
    static let trashScriptArguments = [
        "-e", "tell application \"Finder\"", "-e", "set out to \"\"",
        "-e", "repeat with i in (items of trash)", "-e", "set out to out & POSIX path of (i as alias) & linefeed",
        "-e", "end repeat", "-e", "return out", "-e", "end tell",
    ]
    static let userLocations = ["Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Containers",
                                "Library/Group Containers", "Library/Application Scripts", "Library/Saved Application State",
                                "Library/Logs", "Library/HTTPStorages", "Library/WebKit", "Library/LaunchAgents"]
    static let systemLocations = ["/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools", "/Library/Application Support"]
    static let dotLocations = [".config", ".local/share", ".cache"]

    struct TrashedApp { var path: String; var bundleID: String; var name: String }

    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        guard let osascript = ctx.tools.path(for: "osascript") else { return DetectorOutput() }
        let trash = await ctx.runner.run(osascript, Self.trashScriptArguments, timeout: 30)
        guard trash.ok else {
            return DetectorOutput(warnings: ["Sweep couldn't read the Trash to find leftovers. Allow Sweep to control Finder in System Settings > Privacy & Security > Automation."])
        }
        let trashedApps = trash.stdout.split(separator: "\n").map { String($0).hasSuffix("/") ? String($0.dropLast()) : String($0) }
            .filter { $0.hasSuffix(".app") }
        guard !trashedApps.isEmpty else { return DetectorOutput() }

        let dump = await ctx.runner.run(Self.lsregister, ["-dump"], timeout: 120)
        let records = LSRegisterParser.records(dump.stdout)
        let installed = records.filter { r in
            (r.path.hasPrefix("/Applications/") || r.path.hasPrefix("/System/Applications/") || r.path.hasPrefix(ctx.home + "/Applications/"))
                && r.path.hasSuffix(".app") && !r.path.contains(".app/") && ctx.probe.exists(r.path)
        }
        let apps: [TrashedApp] = trashedApps.compactMap { path in
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if let rec = records.first(where: { $0.path == path }) { return TrashedApp(path: path, bundleID: rec.identifier, name: name) }
            if let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"), let id = plist["CFBundleIdentifier"] as? String {
                return TrashedApp(path: path, bundleID: id, name: name)
            }
            return nil
        }
        let pkgs = await ctx.runner.run(Self.pkgutil, ["--pkgs"], timeout: 30)

        var out = DetectorOutput()
        var seen = Set<String>()
        let running = ctx.processes.processes()
        for app in apps where !app.bundleID.hasPrefix("com.apple.") {
            // An updater (brew cask, Sparkle) often leaves the *previous* copy in the Trash while the app stays installed.
            if installed.contains(where: { $0.identifier == app.bundleID }) {
                out.warnings.append("\(app.name) is in the Trash but another copy is still installed, so its data was left alone")
                continue
            }
            let bundleName = (app.path as NSString).lastPathComponent
            if running.contains(where: { p in p.arguments.first.map { $0.contains("/\(bundleName)/Contents/MacOS/") && !$0.contains("/.Trash/") } ?? false }) {
                out.warnings.append("\(app.name) is still running, so its data was left alone")
                continue
            }
            let vendor = app.bundleID.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
            let sibling = installed.first { $0.identifier.lowercased().hasPrefix(vendor + ".") && $0.identifier != app.bundleID }
            let id = app.bundleID.lowercased(), appName = app.name.lowercased()
            let squashed = appName.replacingOccurrences(of: " ", with: "")

            func consider(_ path: String, exact: Bool, extra: [String] = [], selected: Bool? = nil) {
                guard !seen.contains(path), let meta = ctx.probe.meta(path), !meta.isSymlink else { return }
                if !exact, let sibling {
                    out.warnings.append("Kept \(path): \(sibling.name) from the same vendor is still installed and may share it")
                    return
                }
                seen.insert(path)
                let size = meta.isDirectory ? ctx.measure(path) : FileWalker.size(meta)
                var action = ItemFactory.action(for: rule, path: path, toolPath: nil, ctx: ctx)
                var evidence = ["Left behind by \(app.name), which is in the Trash"] + extra
                if path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/") {
                    action = .revealInFinder
                    evidence.append("macOS guards app containers: remove via Finder")
                }
                out.items.append(ItemFactory.make(rule: rule, path: path, title: "\(app.name): \((path as NSString).lastPathComponent)",
                                                  size: size, action: action, evidence: evidence, defaultSelected: selected))
            }
            func classify(_ name: String) -> Bool? {   // true = exact id match, false = name match, nil = no match
                let n = name.lowercased()
                if n.hasPrefix("com.apple.") { return nil }
                // Whole-component match only: "io.x.app" must not match "io.x.application".
                if n == id || n.hasPrefix(id + ".") || n.hasPrefix(id + "-") || n.hasSuffix("." + id) || n.contains("." + id + ".") {
                    return true
                }
                let stem = (n as NSString).deletingPathExtension
                if n == appName || n == squashed || stem == appName || stem == squashed { return false }
                return nil
            }
            for loc in Self.userLocations.map({ "\(ctx.home)/\($0)" }) + Self.systemLocations {
                for name in ctx.probe.children(loc) ?? [] { if let exact = classify(name) { consider(loc + "/" + name, exact: exact) } }
            }
            for loc in Self.dotLocations.map({ "\(ctx.home)/\($0)" }) {
                for name in ctx.probe.children(loc) ?? [] where classify(name) != nil {
                    let p = loc + "/" + name
                    let recent = ctx.probe.meta(p).map { FileWalker.days($0.mtime, ctx.now) < 30 } ?? false
                    let cli = ctx.tools.path(for: name.lowercased()) != nil
                    if recent || cli {
                        consider(p, exact: true, extra: ["A command-line tool with this name is installed or this folder was used recently. Check before removing."], selected: false)
                    } else {
                        consider(p, exact: true)
                    }
                }
            }
            for pkg in pkgs.stdout.split(separator: "\n").map(String.init) where pkg.lowercased().contains(id) || pkg.lowercased().contains(squashed) {
                let path = "pkgutil://\(pkg)"
                guard seen.insert(path).inserted else { continue }
                out.items.append(ItemFactory.make(rule: rule, path: path, title: "\(app.name): installer receipt \(pkg)", size: SizeResult(),
                                                  action: .none(reason: "Needs an administrator. Run in Terminal: sudo pkgutil --forget \(pkg)")))
            }
        }
        return out
    }
}
