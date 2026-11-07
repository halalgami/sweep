import SwiftUI
import SweepCore

// MARK: Plan (dry run)

struct PlanView: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @State private var confirming = false

    var body: some View {
        let p = Palette.current(scheme)
        let plan = model.plan ?? Plan(entries: [])
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        MascotView(mood: .happy, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.planRoutineOnly ? "Routine sweep plan" : "Sweep plan (dry run)").font(Fonts.ui(26, .bold))
                            Text("Nothing has changed yet. Check what's ticked, then press Sweep. Caches and build folders are deleted; everything else goes to the Trash.")
                                .font(Fonts.ui(14)).foregroundStyle(p.secondary)
                        }
                    }
                    ForEach([Tier.safe, .idleArtifact, .needsDecision], id: \.self) { tier in
                        let entries = plan.entries.filter { $0.item.tier == tier }
                        if !entries.isEmpty { TierSection(tier: tier, entries: entries) }
                    }
                    if plan.entries.isEmpty {
                        Text("Nothing to sweep right now.").font(Fonts.ui(15)).platinumPanel()
                    }
                }
                .padding(16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
            PlanFooter(plan: plan, confirming: $confirming)
        }
        .sheet(isPresented: $confirming) { ConfirmSheet(plan: plan).environment(model).environment(\.flavor, model.flavor) }
    }
}

struct TierSection: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    let tier: Tier
    let entries: [PlanEntry]
    var body: some View {
        let p = Palette.current(scheme)
        let allOn = entries.allSatisfy(\.selected)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TierChip(tier: tier)
                Text(tier.label).font(Fonts.ui(17, .bold))
                Spacer()
                if tier == .safe {
                    Toggle("Select all safe items", isOn: Binding(get: { allOn }, set: { model.setTierSelected(.safe, $0) }))
                        .toggleStyle(.checkbox).font(Fonts.ui(13))
                }
            }
            Text(tier == .safe ? "Confirmed together. Items that re-download a lot start unticked."
                 : "Tick each one you want gone. Nothing here is pre-selected.")
                .font(Fonts.ui(12)).foregroundStyle(p.secondary)
            VStack(spacing: 0) {
                ForEach(entries) { e in
                    PlanRow(entry: e)
                    Divider().opacity(0.4)
                }
            }
            .platinumWell(padding: 2)
        }
        .platinumPanel()
    }
}

struct PlanRow: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    let entry: PlanEntry
    var body: some View {
        let p = Palette.current(scheme)
        let item = entry.item
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { entry.selected }, set: { model.setSelected(entry.id, $0) }))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(Text("Include \(item.title)"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(Fonts.ui(14, .semibold)).lineLimit(1)
                    RebuildChip(cost: item.rebuildCost)
                    if item.action == .trash { Chip(text: "TO TRASH", color: Color(hex: 0x6B6F78)) }
                }
                Text(entry.commandPreview.replacingOccurrences(of: model.home, with: "~")).font(Fonts.mono(11)).foregroundStyle(p.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if let hint = item.rebuildHint { Text("Rebuild: \(hint)").font(Fonts.ui(11)).foregroundStyle(p.secondary) }
            }
            Spacer()
            Text(ByteFormat.string(item.physicalBytes)).font(Fonts.ui(14, .bold)).monospacedDigit()
            Button { model.selectedItem = item } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).help("Details")
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
    }
}

struct RebuildChip: View {
    let cost: RebuildCost
    var body: some View {
        switch cost {
        case .none, .low: Chip(text: "REBUILDS EASILY", color: Color(hex: 0x3D9A4E))
        case .medium: Chip(text: "REBUILD TAKES A WHILE", color: Color(hex: 0xB0841A))
        case .high: Chip(text: "BIG RE-DOWNLOAD", color: Color(hex: 0xC8501E))
        }
    }
}

struct PlanFooter: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    let plan: Plan
    @Binding var confirming: Bool
    var body: some View {
        let p = Palette.current(scheme)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(plan.selected.count) selected · frees about \(ByteFormat.string(plan.expectedFreedBytes))").font(Fonts.ui(15, .bold)).monospacedDigit()
                if plan.toTrashBytes > 0 {
                    Text("\(ByteFormat.string(plan.toTrashBytes)) goes to the Trash and is freed when you empty it.").font(Fonts.ui(12)).foregroundStyle(p.secondary)
                }
            }
            Spacer()
            Button("Cancel") { model.screen = .dashboard; model.plan = nil }.buttonStyle(PlatinumButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Sweep \(plan.selected.count) item\(plan.selected.count == 1 ? "" : "s")…") { confirming = true }
                .buttonStyle(GumdropButtonStyle()).disabled(plan.selected.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(p.chassis)
        .overlay(alignment: .top) { Rectangle().fill(p.bevelDark).frame(height: 1) }
    }
}

struct ConfirmSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @Environment(\.dismiss) var dismiss
    let plan: Plan
    var body: some View {
        let p = Palette.current(scheme)
        let deletes = plan.selected.filter { $0.item.action == .hardDelete }
        let trash = plan.selected.filter { $0.item.action == .trash }
        let tools = plan.selected.filter { if case .hardDelete = $0.item.action { return false }; if case .trash = $0.item.action { return false }; return true }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MascotView(mood: .happy, size: 40)
                Text("Ready to sweep?").font(Fonts.ui(22, .bold))
            }
            VStack(alignment: .leading, spacing: 4) {
                if !deletes.isEmpty { Text("• Permanently delete \(deletes.count) cache/build folder(s) (\(ByteFormat.string(deletes.reduce(0) { $0 + $1.item.physicalBytes })))") }
                if !tools.isEmpty { Text("• Run \(tools.count) cleanup command(s) from the tools themselves") }
                if !trash.isEmpty { Text("• Move \(trash.count) item(s) to the Trash (\(ByteFormat.string(trash.reduce(0) { $0 + $1.item.physicalBytes })))") }
            }.font(Fonts.ui(14))
            Text("Every item is checked again right before it's touched. Anything that changed since the scan is skipped and reported.")
                .font(Fonts.ui(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PlatinumButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Sweep now") { dismiss(); model.execute() }.buttonStyle(GumdropButtonStyle())
            }
        }
        .padding(20).frame(width: 480).background(p.chassis).foregroundStyle(p.text)
    }
}

// MARK: Execute

struct ExecuteView: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @State private var shade = false
    var body: some View {
        let p = Palette.current(scheme)
        let total = max(1, model.plan?.selected.count ?? 1)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                MascotView(mood: .working, hopTrigger: model.results.count, size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sweeping…").font(Fonts.ui(26, .bold))
                    Text(model.currentItem?.title ?? "Finishing up").font(Fonts.ui(14)).foregroundStyle(p.secondary)
                    JellyBar(fraction: Double(model.results.count) / Double(total), striped: true, height: 18).frame(maxWidth: 560)
                    Text("\(model.results.count) of \(total) done").font(Fonts.ui(12)).foregroundStyle(p.secondary).monospacedDigit()
                }
            }
            .platinumPanel(padding: 16)
            ResultsList(results: model.results)
            LogPanel(lines: model.executionLog, shade: $shade)
        }
        .padding(16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
    }
}

struct ResultsList: View {
    let results: [ItemResult]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GroovedHeader(title: "Results")
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(results) { r in
                        HStack {
                            Image(systemName: icon(r.status)).foregroundStyle(color(r.status))
                            Text(r.title).font(Fonts.ui(13, .semibold)).lineLimit(1)
                            Text(r.status.label).font(Fonts.ui(12)).foregroundStyle(color(r.status))
                            Spacer()
                            Text(r.message).font(Fonts.ui(12)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 420, alignment: .trailing)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(minHeight: 140).platinumWell(padding: 2)
        }
        .platinumPanel()
    }
    func icon(_ s: ItemStatus) -> String {
        switch s { case .removed: "checkmark.circle.fill"; case .trashed: "trash.circle.fill"; case .partial: "circle.lefthalf.filled"
        case .protectedByMacOS: "lock.circle.fill"; case .blocked: "hand.raised.circle.fill"; case .failed: "xmark.octagon.fill" }
    }
    func color(_ s: ItemStatus) -> Color {
        switch s { case .removed, .trashed: Color(hex: 0x3D9A4E); case .partial, .protectedByMacOS: Color(hex: 0xB0841A)
        case .blocked: Color(hex: 0x6B6F78); case .failed: Color(hex: 0xC8302E) }
    }
}

/// Live log with a Platinum "window shade": double-click the title to roll it up.
struct LogPanel: View {
    @Environment(\.colorScheme) var scheme
    let lines: [String]
    @Binding var shade: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroovedHeader(title: shade ? "Log (double-click to open)" : "Live log")
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { withAnimation(.spring(response: 0.35)) { shade.toggle() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { shade.toggle() }
            if !shade {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                                Text(l).font(Fonts.mono(11)).frame(maxWidth: .infinity, alignment: .leading).id(i).textSelection(.enabled)
                            }
                        }
                    }
                    .onChange(of: lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
                .frame(minHeight: 120, maxHeight: 220).platinumWell()
            }
        }
        .platinumPanel()
    }
}

// MARK: Verify

struct VerifyView: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @State private var shade = true
    @State private var confirmEmpty = false
    var body: some View {
        let p = Palette.current(scheme)
        let v = model.verification
        let removed = model.results.filter { $0.status == .removed }.count
        let partial = model.results.filter { $0.status == .partial }.count
        let protectedCount = model.results.reduce(0) { $0 + $1.protectedPaths }
        let skipped = model.results.filter { $0.status == .blocked }.count
        let failed = model.results.filter { $0.status == .failed }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    MascotView(mood: .happy, hopTrigger: model.mascotHop, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failed == 0 ? "Room to breathe again." : "Done, with a few hiccups.").font(Fonts.ui(28, .bold))
                        Text(summaryLine(removed: removed, partial: partial, protected: protectedCount, skipped: skipped, failed: failed))
                            .font(Fonts.ui(14)).foregroundStyle(p.secondary)
                    }
                }
                .platinumPanel(padding: 16)
                if let v {
                    HStack(spacing: 14) {
                        Stat(title: "Expected to free", value: ByteFormat.string(v.expectedBytes))
                        Stat(title: "Free space gained so far", value: ByteFormat.string(max(0, v.freedNowBytes)))
                        Stat(title: "Waiting in the Trash", value: ByteFormat.string(v.trashedBytes))
                    }
                    if v.lagLikely {
                        HStack(spacing: 8) {
                            Image(systemName: "hourglass")
                            Text(model.recheckAt != nil
                                 ? "macOS hasn't caught up yet. APFS frees space in the background and snapshots can hold it a little longer. Checking again in a minute…"
                                 : "Free space is still catching up. That's normal for APFS. It can take a few minutes after a big cleanup.")
                                .font(Fonts.ui(13)).fixedSize(horizontal: false, vertical: true)
                        }.platinumPanel()
                    }
                    if v.trashedBytes > 0 {
                        HStack {
                            Text("Items moved to the Trash still take up space until you empty it.").font(Fonts.ui(13))
                            Spacer()
                            Button("Empty Trash…") { confirmEmpty = true }.buttonStyle(PlatinumButtonStyle())
                                .confirmationDialog("Empty the whole Trash?", isPresented: $confirmEmpty) {
                                    Button("Empty Trash", role: .destructive) { model.emptyTrash() }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("This permanently deletes everything in your Trash, not only what Sweep moved there. It can't be undone.")
                                }
                        }.platinumPanel()
                    }
                }
                ResultsList(results: model.results)
                LogPanel(lines: model.executionLog, shade: $shade)
                HStack { Spacer(); Button("Back to dashboard") { model.finishRun() }.buttonStyle(GumdropButtonStyle()).keyboardShortcut(.defaultAction) }
            }
            .padding(16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
    }

    func summaryLine(removed: Int, partial: Int, protected: Int, skipped: Int, failed: Int) -> String {
        var parts = ["\(removed) removed"]
        if partial > 0 { parts.append("\(partial) partly removed") }
        if protected > 0 { parts.append("\(protected) file(s) protected by macOS") }
        if skipped > 0 { parts.append("\(skipped) skipped for safety") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ") + "."
    }
}

struct Stat: View {
    @Environment(\.colorScheme) var scheme
    let title: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(Fonts.ui(11, .bold)).tracking(0.6).foregroundStyle(Palette.current(scheme).secondary)
            Text(value).font(Fonts.ui(26, .bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .platinumPanel()
    }
}
