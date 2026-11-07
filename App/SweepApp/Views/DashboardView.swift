import Charts
import SwiftUI
import SweepCore

struct DashboardView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HeroPanel()
                APFSPanel()
                HStack(alignment: .top, spacing: 14) {
                    ReclaimPanel().frame(maxWidth: 380)
                    DecisionPanel()
                }
                HStack(alignment: .top, spacing: 14) {
                    TreemapPanel()
                    GrowthPanel().frame(maxWidth: 420)
                }
                if model.insightsEnabled { InsightsPanel() }
                NotesPanel()
            }
            .padding(16)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Hero

struct HeroPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let p = Palette.current(scheme)
        let v = model.volume
        HStack(alignment: .center, spacing: 18) {
            MascotView(mood: model.mascotMood, hopTrigger: model.mascotHop, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("FREE SPACE").font(Fonts.ui(12, .bold)).tracking(0.8).foregroundStyle(p.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ByteFormat.string(v.freeBytes)).font(Fonts.ui(40, .bold)).monospacedDigit()
                    Text("of \(ByteFormat.string(v.totalBytes))").font(Fonts.ui(16)).foregroundStyle(p.secondary)
                }
                JellyBar(fraction: v.totalBytes > 0 ? Double(v.totalBytes - v.freeBytes) / Double(v.totalBytes) : 0,
                         striped: model.scanning, tint: model.freeFraction < 0.1 ? Color(hex: 0xE2445C) : nil, height: 16)
                    .frame(maxWidth: 520)
                    .modifier(BalloonHelp(text: "How full your startup disk is. Free space counts what macOS can make available, including purgeable space.", enabled: model.balloonHelp))
                HStack(spacing: 14) {
                    Text("\(ByteFormat.string(v.totalBytes - v.freeBytes)) used").font(Fonts.ui(13)).foregroundStyle(p.secondary)
                    if let d = model.daysToFull {
                        Text("At this pace the disk fills in about \(Int(d)) days").font(Fonts.ui(13, .semibold)).foregroundStyle(Color(hex: 0xC8501E))
                    }
                    if let r = model.report {
                        Text("Scanned \(r.scannedAt.formatted(date: .omitted, time: .shortened))").font(Fonts.ui(13)).foregroundStyle(p.secondary)
                    }
                }
            }
            Spacer(minLength: 10)
            SpeechBubble(text: model.bubbleText).frame(maxWidth: 260)
        }
        .platinumPanel(padding: 16)
    }
}

// MARK: APFS container

struct APFSPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    static func color(_ role: String) -> Color {
        switch role {
        case "System": Color(hex: 0x4B5066)
        case "Preboot": Color(hex: 0x8A4FC7)
        case "VM": Color(hex: 0xFF8A1F)
        case "Data": Color(hex: 0x2F7FD6)
        case "Simulator": Color(hex: 0x5FBF2F)
        case "Free": Color(hex: 0xF4F4F4)
        default: Color(hex: 0x9AA0AA)
        }
    }
    var body: some View {
        let p = Palette.current(scheme)
        let vols = (model.report?.apfs ?? []).filter { !$0.isSimulator }
        let groups = Dictionary(grouping: vols, by: { ["System", "Preboot", "VM", "Data"].contains($0.role) ? $0.role : "Other" })
            .mapValues { $0.reduce(Int64(0)) { $0 + $1.usedBytes } }
        let sims = (model.report?.apfs ?? []).filter(\.isSimulator).reduce(Int64(0)) { $0 + $1.usedBytes }
        let order = ["System", "Preboot", "VM", "Data", "Other"]
        var segs = order.compactMap { r in groups[r].map { SegmentBar.Segment(id: r, color: Self.color(r), value: Double($0)) } }
        if sims > 0 { segs.append(.init(id: "Simulator", color: Self.color("Simulator"), value: Double(sims))) }
        segs.append(.init(id: "Free", color: Self.color("Free"), value: Double(model.volume.freeBytes)))
        return VStack(alignment: .leading, spacing: 8) {
            GroovedHeader(title: "Startup disk (APFS container)")
            if vols.isEmpty {
                Text(model.scanning ? "Measuring…" : "Run a scan to see the breakdown.").font(Fonts.ui(13)).foregroundStyle(p.secondary)
            } else {
                SegmentBar(segments: segs)
                    .modifier(BalloonHelp(text: "APFS volumes share one container. System and Preboot belong to macOS; VM is swap; Data is your stuff. Simulator runtimes live in their own disk images.", enabled: model.balloonHelp))
                FlowLegend(items: segs.map { s in
                    let bytes: Int64 = s.id == "Free" ? model.volume.freeBytes : s.id == "Simulator" ? sims : groups[s.id] ?? 0
                    return (s.color, "\(s.id) \(ByteFormat.string(bytes))")
                })
                if let snaps = model.report?.snapshots, !snaps.isEmpty {
                    Text("\(snaps.count) local snapshot(s) hold some deleted data. After big cleanups, free space can take a few minutes to catch up.")
                        .font(Fonts.ui(12)).foregroundStyle(p.secondary)
                }
            }
        }
        .platinumPanel()
    }
}

struct FlowLegend: View {
    let items: [(Color, String)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 5) {
                    Circle().fill(it.0).overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 0.5)).frame(width: 10, height: 10)
                    Text(it.1).font(Fonts.ui(12)).monospacedDigit()
                }
            }
        }
    }
}

// MARK: Reclaimable now

struct ReclaimPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let p = Palette.current(scheme)
        let safe = model.safeItems
        VStack(alignment: .leading, spacing: 8) {
            GroovedHeader(title: "Reclaimable now")
            Text(ByteFormat.string(model.reclaimableNow)).font(Fonts.ui(30, .bold)).monospacedDigit()
            Text("\(safe.count) safe caches. Apps and tools rebuild them on their own.").font(Fonts.ui(13)).foregroundStyle(p.secondary)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(safe.prefix(5)) { item in
                    Button { model.selectedItem = item } label: {
                        HStack {
                            Text(item.title).font(Fonts.ui(13)).lineLimit(1)
                            Spacer()
                            Text(ByteFormat.string(item.physicalBytes)).font(Fonts.ui(13, .semibold)).monospacedDigit()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if safe.count > 5 { Text("and \(safe.count - 5) more").font(Fonts.ui(12)).foregroundStyle(p.secondary) }
            }
            .platinumWell()
            HStack {
                Button("Review & sweep…") { model.openPlan() }
                    .buttonStyle(GumdropButtonStyle())
                    .disabled(model.report == nil || model.scanning || safe.isEmpty)
                    .modifier(BalloonHelp(text: "Opens a dry-run plan first. Nothing is removed until you confirm.", enabled: model.balloonHelp))
                Spacer()
            }
        }
        .platinumPanel()
    }
}

// MARK: Needs your decision

struct TierChip: View {
    let tier: Tier
    var body: some View {
        switch tier {
        case .safe: Chip(text: "SAFE", color: Color(hex: 0x3D9A4E))
        case .idleArtifact: Chip(text: "IDLE BUILD", color: Color(hex: 0x2F7FD6))
        case .needsDecision: Chip(text: "YOUR CALL", color: Color(hex: 0xC8701E))
        case .protected: Chip(text: "PROTECTED", color: Color(hex: 0x6B6F78))
        }
    }
}

struct DecisionPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let p = Palette.current(scheme)
        let items = model.decisionItems
        VStack(alignment: .leading, spacing: 8) {
            GroovedHeader(title: "Needs your decision")
            if items.isEmpty {
                Text(model.report == nil ? "Waiting for the first scan." : "Nothing big waiting on you.").font(Fonts.ui(13)).foregroundStyle(p.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).platinumWell()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items.prefix(60)) { item in
                            Button { model.selectedItem = item } label: { ItemRow(item: item) }.buttonStyle(.plain)
                            Divider().opacity(0.5)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 260)
                .platinumWell(padding: 4)
            }
            HStack {
                Text("Each one is confirmed on its own. Big re-downloads are never pre-selected.").font(Fonts.ui(12)).foregroundStyle(p.secondary)
                Spacer()
                Button("Review all…") { model.openPlan() }.buttonStyle(PlatinumButtonStyle()).disabled(items.isEmpty)
            }
        }
        .platinumPanel()
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    let item: Item
    var body: some View {
        let p = Palette.current(scheme)
        HStack(spacing: 8) {
            TierChip(tier: item.tier)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Fonts.ui(14, .semibold)).lineLimit(1)
                Text(item.evidence.first ?? item.path.replacingOccurrences(of: model.home, with: "~"))
                    .font(Fonts.ui(12)).foregroundStyle(p.secondary).lineLimit(1)
            }
            Spacer()
            if let rate = model.growthRates[item.id], abs(rate) > 50_000_000 {
                Text(ByteFormat.rate(rate)).font(Fonts.ui(11, .bold)).foregroundStyle(rate > 0 ? Color(hex: 0xC8501E) : Color(hex: 0x3D9A4E))
            }
            Text(ByteFormat.string(item.physicalBytes)).font(Fonts.ui(14, .bold)).monospacedDigit()
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

// MARK: Treemap

struct TreemapPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @State private var drill: Bucket?
    static let palette: [Color] = [0x2F7FD6, 0x8A4FC7, 0xFF8A1F, 0x0A9BB8, 0x5FBF2F, 0xE2445C, 0x4B5066, 0xC8A21E].map { Color(hex: $0) }

    struct Tile: Identifiable { let id: String; let label: String; let bytes: Int64; let bucket: Bucket?; let color: Color }

    var body: some View {
        let p = Palette.current(scheme)
        let report = model.report
        var tiles: [Tile] = []
        if let drill {
            tiles = drill.children.enumerated().map { i, b in
                Tile(id: b.path, label: (b.path as NSString).lastPathComponent, bytes: b.physicalBytes, bucket: nil, color: Self.palette[i % Self.palette.count])
            }
            let rest = drill.physicalBytes - drill.children.reduce(0) { $0 + $1.physicalBytes }
            if rest > 0 { tiles.append(Tile(id: "rest", label: "Other", bytes: rest, bucket: nil, color: Color(hex: 0x9AA0AA))) }
        } else if let report {
            tiles = report.buckets.enumerated().map { i, b in
                Tile(id: b.path, label: b.path.replacingOccurrences(of: model.home, with: "~ (home)"), bytes: b.physicalBytes, bucket: b,
                     color: Self.palette[i % Self.palette.count])
            }
            if report.unaccountedBytes > 0 {
                tiles.append(Tile(id: "unaccounted", label: "Unaccounted", bytes: report.unaccountedBytes, bucket: nil, color: Color(hex: 0x6B6F78)))
            }
        }
        tiles.sort { $0.bytes > $1.bytes }
        return VStack(alignment: .leading, spacing: 8) {
            GroovedHeader(title: drill.map { "Where it went: \($0.path.replacingOccurrences(of: model.home, with: "~"))" } ?? (model.measuringFolders ? "Where it went (measuring…)" : "Where it went"),
                          trailing: drill == nil ? nil : AnyView(Button("Back") { drill = nil }.buttonStyle(PlatinumButtonStyle())))
            if tiles.isEmpty {
                Text(model.scanning || model.measuringFolders ? "Measuring folders… this takes a minute or two. Everything else is ready." : "Run a scan to see folder sizes.")
                    .font(Fonts.ui(13)).foregroundStyle(p.secondary).frame(maxWidth: .infinity, minHeight: 240).platinumWell()
            } else {
                GeometryReader { geo in
                    let rects = Treemap.squarify(tiles.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: geo.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(zip(tiles, rects)), id: \.0.id) { tile, r in
                            Button {
                                if let b = tile.bucket, !b.children.isEmpty { withAnimation(.spring(response: 0.4)) { drill = b } }
                                else if tile.id == "unaccounted" { model.openFullDiskAccessSettings() }
                                else if tile.id.hasPrefix("/") { model.reveal(tile.id) }
                            } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(LinearGradient(colors: [tile.color.mix(with: .white, by: 0.35), tile.color], startPoint: .top, endPoint: .bottom))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.35), lineWidth: 0.7))
                                    .overlay(alignment: .topLeading) {
                                        if r.width > 70 && r.height > 34 {
                                            VStack(alignment: .leading, spacing: 0) {
                                                Text(tile.label).font(Fonts.ui(12, .bold)).lineLimit(1)
                                                Text(ByteFormat.string(tile.bytes)).font(Fonts.ui(12)).monospacedDigit()
                                            }.foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 0, y: 0.5).padding(6)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .frame(width: max(0, r.width - 3), height: max(0, r.height - 3))
                            .offset(x: r.minX, y: r.minY)
                            .help("\(tile.label): \(ByteFormat.string(tile.bytes))")
                        }
                    }
                }
                .frame(minHeight: 260)
                .platinumWell(padding: 4)
            }
            if let r = report, !r.fullDiskAccess, r.unaccountedBytes > 0, drill == nil {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(Color(hex: 0xC8701E))
                    Text("\(ByteFormat.string(r.unaccountedBytes)) is unaccounted for. That's usually Mail, Messages, Safari and other folders macOS protects. Give Sweep Full Disk Access to measure them. Everything else works without it.")
                        .font(Fonts.ui(12)).foregroundStyle(p.secondary)
                    Spacer()
                    Button("Open Settings") { model.openFullDiskAccessSettings() }.buttonStyle(PlatinumButtonStyle())
                }
            }
        }
        .platinumPanel()
    }
}

// MARK: Growth

struct GrowthPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @Environment(\.flavor) var flavor
    var body: some View {
        let p = Palette.current(scheme)
        let growers = (model.report?.items ?? []).compactMap { i in model.growthRates[i.id].map { (i, $0) } }
            .filter { $0.1 > 10_000_000 }.sorted { $0.1 > $1.1 }.prefix(5)
        VStack(alignment: .leading, spacing: 8) {
            GroovedHeader(title: "Free space, last 30 days")
            if model.freeSeries.count < 2 {
                Text("Growth trends appear after a few scans on different days.").font(Fonts.ui(13)).foregroundStyle(p.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120).platinumWell()
            } else {
                Chart(model.freeSeries, id: \.date) { pt in
                    AreaMark(x: .value("Date", pt.date), y: .value("Free GB", Double(pt.bytes) / 1e9))
                        .foregroundStyle(LinearGradient(colors: [flavor.color.opacity(0.35), flavor.color.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", pt.date), y: .value("Free GB", Double(pt.bytes) / 1e9)).foregroundStyle(flavor.dark)
                }
                .chartYAxisLabel("GB free")
                .frame(height: 130)
                .platinumWell()
            }
            GroovedHeader(title: "Growing fastest")
            if growers.isEmpty {
                Text("Nothing is growing quickly.").font(Fonts.ui(13)).foregroundStyle(p.secondary)
            } else {
                ForEach(Array(growers), id: \.0.id) { item, rate in
                    HStack {
                        Text(item.title).font(Fonts.ui(13)).lineLimit(1)
                        Spacer()
                        Text(ByteFormat.rate(rate)).font(Fonts.ui(13, .bold)).foregroundStyle(Color(hex: 0xC8501E)).monospacedDigit()
                    }
                }
            }
            if let hints = model.report?.rootCauses, !hints.isEmpty {
                GroovedHeader(title: "Why caches keep growing")
                ForEach(hints.prefix(4)) { h in
                    Text("• \(h.detail)").font(Fonts.ui(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if hints.count > 4 { Text("and \(hints.count - 4) more").font(Fonts.ui(12)).foregroundStyle(p.secondary) }
            }
        }
        .platinumPanel()
    }
}

// MARK: Notes (warnings + protected)

struct NotesPanel: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @State private var showProtected = false
    var body: some View {
        let p = Palette.current(scheme)
        let protectedTotal = model.protectedItems.reduce(Int64(0)) { $0 + $1.physicalBytes }
        if !model.warnings.isEmpty || !model.protectedItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                GroovedHeader(title: "Notes from the last scan")
                ForEach(model.warnings, id: \.self) { w in
                    Text("• \(w)").font(Fonts.ui(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !model.protectedItems.isEmpty {
                    DisclosureGroup(isExpanded: $showProtected) {
                        ForEach(model.protectedItems) { item in
                            Button { model.selectedItem = item } label: { ItemRow(item: item) }.buttonStyle(.plain)
                        }
                    } label: {
                        Text("\(model.protectedItems.count) protected item(s), \(ByteFormat.string(protectedTotal)), shown so the numbers add up. Sweep won't touch these.")
                            .font(Fonts.ui(12, .semibold))
                    }
                }
            }
            .platinumPanel()
        }
    }
}
