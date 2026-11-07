import Charts
import SwiftUI
import SweepCore

struct MenuBarView: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @Environment(\.flavor) var flavor
    @Environment(\.openWindow) var openWindow
    @Environment(\.openSettings) var openSettings

    var body: some View {
        let p = Palette.current(scheme)
        let week = model.freeSeries.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MascotView(mood: model.mascotMood, hopTrigger: model.mascotHop, size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(ByteFormat.string(model.volume.freeBytes)) free").font(Fonts.ui(20, .bold)).monospacedDigit()
                    Text("of \(ByteFormat.string(model.volume.totalBytes))").font(Fonts.ui(12)).foregroundStyle(p.secondary)
                }
                Spacer()
            }
            JellyBar(fraction: 1 - model.freeFraction, striped: model.executing, height: 12)
            if week.count >= 2 {
                Chart(week, id: \.date) { pt in
                    AreaMark(x: .value("Day", pt.date), y: .value("GB", Double(pt.bytes) / 1e9))
                        .foregroundStyle(flavor.color.opacity(0.25))
                    LineMark(x: .value("Day", pt.date), y: .value("GB", Double(pt.bytes) / 1e9)).foregroundStyle(flavor.dark)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 40)
                Text("Free space, last 7 days").font(Fonts.ui(11)).foregroundStyle(p.secondary)
            }
            Divider()
            if model.routineConsented {
                Text("Run safe sweep removes:").font(Fonts.ui(12, .bold))
                Text(model.routineRules.map(\.title).joined(separator: ", ")).font(Fonts.ui(12)).foregroundStyle(p.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.routineEstimate > 0 {
                    Text("About \(ByteFormat.string(model.routineEstimate)) right now").font(Fonts.ui(12)).monospacedDigit()
                }
                Button(model.executing ? "Sweeping…" : "Run safe sweep") { model.runRoutineNow() }
                    .buttonStyle(GumdropButtonStyle()).disabled(model.executing)
            } else {
                Text("One-click sweeps are off. Review exactly what they'd remove first.").font(Fonts.ui(12)).foregroundStyle(p.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review routine sweep…") { openSettings() }.buttonStyle(GumdropButtonStyle())
            }
            if let msg = model.maintenanceMessage { Text(msg).font(Fonts.ui(11)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Button("Open Sweep") { openWindow(id: "main"); NSApp.activate() }.buttonStyle(PlatinumButtonStyle())
                Button("Scan") { model.scan() }.buttonStyle(PlatinumButtonStyle()).disabled(model.scanning)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(PlatinumButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(p.chassis)
        .foregroundStyle(p.text)
    }
}
