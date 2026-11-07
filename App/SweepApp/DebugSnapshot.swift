#if DEBUG
import AppKit

/// Debug-only: `SWEEP_SNAPSHOT=/path/prefix` makes the app write PNGs of its own main window (no Screen Recording needed).
enum DebugSnapshot {
    static var prefix: String? { ProcessInfo.processInfo.environment["SWEEP_SNAPSHOT"] }

    @MainActor static func capture(_ name: String) {
        guard let prefix, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
              let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
    }
}
#endif
