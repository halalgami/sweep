import SwiftUI
import SweepCore

struct InsightsPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @State private var showPayload = false
    var body: some View {
        let p = Palette.current(scheme)
        VStack(alignment: .leading, spacing: 8) {
            GroovedHeader(title: "Insights", trailing: AnyView(HStack(spacing: 6) {
                Button("View payload") { showPayload = true }.buttonStyle(PlatinumButtonStyle()).disabled(model.summary == nil)
                Button(model.insightsLoading ? "Thinking…" : "Explain my disk") { model.runInsights() }
                    .buttonStyle(GumdropButtonStyle())
                    .disabled(model.summary == nil || model.insightsLoading || !model.payloadViewed)
            }))
            if !model.payloadViewed {
                Text("Before the first request, press View payload to see exactly what would be sent. It's a summary built by Sweep: sizes, categories and redacted paths. No file contents, no personal file names.")
                    .font(Fonts.ui(13)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let err = model.insightsError {
                Text("Insights unavailable: \(err). Everything else keeps working.").font(Fonts.ui(13)).foregroundStyle(Color(hex: 0xC8501E))
            }
            if let r = model.insights {
                Text(r.headline).font(Fonts.ui(18, .bold))
                ForEach(Array(r.insights.enumerated()), id: \.offset) { _, ins in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ins.title).font(Fonts.ui(14, .semibold))
                        Text(ins.detail).font(Fonts.ui(13)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !r.recommendations.isEmpty {
                    GroovedHeader(title: "Suggested next steps")
                    ForEach(Array(r.recommendations.enumerated()), id: \.offset) { i, rec in
                        let items = rec.itemIds.compactMap(model.item(id:))
                        // Byte totals are computed by Sweep from the referenced items, never taken from the AI.
                        let bytes = items.reduce(Int64(0)) { $0 + $1.physicalBytes }
                        HStack(alignment: .top) {
                            Text("\(i + 1).").font(Fonts.ui(14, .bold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.action).font(Fonts.ui(14, .semibold))
                                Text(rec.why).font(Fonts.ui(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 6) {
                                    ForEach(items) { it in Button(it.title) { model.selectedItem = it }.buttonStyle(.link).font(Fonts.ui(12)) }
                                }
                            }
                            Spacer()
                            Text(ByteFormat.string(bytes)).font(Fonts.ui(14, .bold)).monospacedDigit()
                        }
                    }
                }
                if !r.maintenanceSuggestions.isEmpty {
                    GroovedHeader(title: "Keep it tidy")
                    ForEach(r.maintenanceSuggestions, id: \.self) { Text("• \($0)").font(Fonts.ui(13)) }
                }
                if !r.questionsForUser.isEmpty {
                    GroovedHeader(title: "Questions for you")
                    ForEach(r.questionsForUser, id: \.self) { Text("• \($0)").font(Fonts.ui(13)) }
                }
            }
        }
        .platinumPanel()
        .sheet(isPresented: $showPayload) { PayloadSheet().environment(model).environment(\.flavor, model.flavor) }
    }
}

struct PayloadSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @Environment(\.dismiss) var dismiss
    var body: some View {
        let p = Palette.current(scheme)
        VStack(alignment: .leading, spacing: 10) {
            Text("Exactly what would be sent").font(Fonts.ui(20, .bold))
            Text("Provider: \(model.providerDescription) Usernames become ~, project and file names in your folders become project_NN, and sensitive files are fully redacted.")
                .font(Fonts.ui(13)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(model.summary?.json() ?? "{}").font(Fonts.mono(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .platinumWell()
            HStack {
                Spacer()
                Button("Close") { model.payloadViewed = true; dismiss() }.buttonStyle(GumdropButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 720, height: 560).background(p.chassis).foregroundStyle(p.text)
    }
}
