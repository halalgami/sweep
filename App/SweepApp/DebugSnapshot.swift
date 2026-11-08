#if DEBUG
import AppKit
import SweepCore

/// Debug-only: `SWEEP_SNAPSHOT=/path/prefix` makes the app write PNGs of its own windows (no Screen Recording needed).
enum DebugSnapshot {
    static var prefix: String? { ProcessInfo.processInfo.environment["SWEEP_SNAPSHOT"] }

    @MainActor static func capture(_ name: String, window: NSWindow? = nil) {
        guard let prefix,
              let window = window ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 && $0.title == "Sweep" }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
    }
}

/// Debug-only demo used for the README screenshots: `SWEEP_DEMO=1 SWEEP_SNAPSHOT=/tmp/shot [SWEEP_APPEARANCE=dark]`.
/// Loads made-up data (never your disk), walks through the screens, writes PNGs and quits.
@MainActor
enum DemoTour {
    static var openSettings: (() -> Void)?

    static func scrollToBottom(_ window: NSWindow) {
        func find(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView, s.documentView?.frame.height ?? 0 > s.contentView.bounds.height + 50 { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        guard let root = window.contentView, let sv = find(root), let doc = sv.documentView else { return }
        let y = doc.isFlipped ? doc.frame.height - sv.contentView.bounds.height : 0
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }
    static func load(into m: AppModel) {
        let report = DemoData.report(home: m.home)
        m.report = report
        m.freeSeries = DemoData.freeSeries()
        m.growthRates = DemoData.growth(report.items)
        m.decisions = [:]
        m.warnings = report.warnings
        m.insightsEnabled = true
        m.payloadViewed = true
        m.insights = DemoData.insights(report.items)
        if DebugSnapshot.prefix != nil { Task { await run(m) } }
    }

    static func run(_ m: AppModel) async {
        let dark = ProcessInfo.processInfo.environment["SWEEP_APPEARANCE"] == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let suffix = dark ? "-dark" : ""
        func pause(_ s: Double = 1.2) async { try? await Task.sleep(for: .seconds(s)) }
        await pause(1.5)
        guard let main = NSApp.windows.first(where: { $0.title == "Sweep" && $0.isVisible }) else { NSApp.terminate(nil); return }
        main.setFrame(NSRect(x: 40, y: 40, width: 1240, height: 900), display: true)
        await pause()
        DebugSnapshot.capture("dashboard\(suffix)")

        // Lower half of the dashboard: treemap, growth, insights.
        scrollToBottom(main)
        await pause()
        DebugSnapshot.capture("dashboard-bottom\(suffix)")

        if let vm = m.report?.items.first(where: { $0.category == "decision.vms" }) {
            m.selectedItem = vm
            await pause()
            if let sheet = main.attachedSheet { DebugSnapshot.capture("detail\(suffix)", window: sheet) }
            m.selectedItem = nil
            await pause(0.6)
        }

        m.openPlan()
        await pause()
        DebugSnapshot.capture("plan\(suffix)")

        let (results, verification) = DemoData.verification(m.report?.items ?? [])
        m.results = results
        m.verification = verification
        m.executionLog = ["Dry run confirmed. Starting \(results.count) item(s)…"] + results.flatMap { ["• \($0.title)", "  \($0.status.label): \($0.message)"] }
        m.screen = .verify
        await pause()
        DebugSnapshot.capture("verify\(suffix)")
        m.screen = .dashboard
        m.plan = nil

        m.settingsTab = "insights"
        openSettings?()
        await pause(1.5)
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.frame.width >= 500 && $0.title != "Sweep" }) {
            DebugSnapshot.capture("settings-insights\(suffix)", window: settings)
            m.settingsTab = "maintenance"
            await pause()
            DebugSnapshot.capture("settings-maintenance\(suffix)", window: settings)
        }
        NSApp.terminate(nil)
    }
}
#endif
