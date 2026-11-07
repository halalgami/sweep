import Charts
import SwiftUI
import SweepCore

struct ItemDetailSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @Environment(\.dismiss) var dismiss
    @Environment(\.flavor) var flavor
    let item: Item

    var body: some View {
        let p = Palette.current(scheme)
        let series = model.series(for: item)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                TierChip(tier: item.tier)
                Text(item.title).font(Fonts.ui(22, .bold)).lineLimit(2)
                Spacer()
                Text(ByteFormat.string(item.physicalBytes)).font(Fonts.ui(22, .bold)).monospacedDigit()
            }
            if item.path.hasPrefix("/") {
                Text(item.path.replacingOccurrences(of: model.home, with: "~")).font(Fonts.mono(12)).foregroundStyle(p.secondary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                GroovedHeader(title: "Why Sweep thinks this")
                ForEach(item.evidence, id: \.self) { Text("• \($0)").font(Fonts.ui(13)).fixedSize(horizontal: false, vertical: true) }
                if item.logicalBytes > item.physicalBytes * 2 && item.physicalBytes > 0 {
                    Text("• Files report \(ByteFormat.string(item.logicalBytes)), but only \(ByteFormat.string(item.physicalBytes)) is stored on this Mac.").font(Fonts.ui(13))
                }
                if let rule = model.rules.rule(item.category) {
                    Text(rule.explanation).font(Fonts.ui(13)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).platinumWell(padding: 10)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Action").foregroundStyle(p.secondary); Text(item.action.preview(path: item.path.replacingOccurrences(of: model.home, with: "~"))).font(Fonts.mono(12)).textSelection(.enabled) }
                GridRow { Text("Rebuild cost").foregroundStyle(p.secondary); Text("\(item.rebuildCost.rawValue)\(item.rebuildHint.map { " – \($0)" } ?? "")") }
                if let d = item.lastUsedSignal { GridRow { Text("Last used").foregroundStyle(p.secondary); Text(d.formatted(date: .abbreviated, time: .omitted)) } }
                if let rate = model.growthRates[item.id] { GridRow { Text("Growth").foregroundStyle(p.secondary); Text(ByteFormat.rate(rate)) } }
            }
            .font(Fonts.ui(13))
            if series.count >= 2 {
                Chart(series, id: \.date) { LineMark(x: .value("Date", $0.date), y: .value("GB", Double($0.bytes) / 1e9)).foregroundStyle(flavor.dark) }
                    .frame(height: 90).platinumWell()
            }
            HStack {
                if item.path.hasPrefix("/") { Button("Reveal in Finder") { model.reveal(item.path) }.buttonStyle(PlatinumButtonStyle()) }
                Spacer()
                if model.decisions[item.id] != nil {
                    Button("Ask me again") { model.forget(item); dismiss() }.buttonStyle(PlatinumButtonStyle())
                } else if item.tier != .protected {
                    Button("Keep for 90 days") { model.keep(item); dismiss() }.buttonStyle(PlatinumButtonStyle())
                        .modifier(BalloonHelp(text: "Sweep won't suggest this again for 90 days.", enabled: model.balloonHelp))
                    Button("Never ask") { model.neverAsk(item); dismiss() }.buttonStyle(PlatinumButtonStyle())
                }
                Button("Done") { dismiss() }.buttonStyle(GumdropButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(p.chassis)
        .foregroundStyle(p.text)
    }
}
