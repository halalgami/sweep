import AppKit
import SwiftUI
import SweepCore

struct SettingsView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "paintpalette") }.tag("general")
            ScanningSettings().tabItem { Label("Scanning", systemImage: "magnifyingglass") }.tag("scanning")
            MaintenanceSettings().tabItem { Label("Maintenance", systemImage: "calendar") }.tag("maintenance")
            InsightsSettings().tabItem { Label("Insights", systemImage: "sparkles") }.tag("insights")
        }
        .frame(width: 600, height: 520)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Flavour") {
                HStack(spacing: 14) {
                    ForEach(Flavor.allCases) { f in
                        Button { model.flavor = f } label: {
                            VStack(spacing: 4) {
                                Circle().fill(RadialGradient(colors: [f.extraLight, f.color, f.dark], center: .init(x: 0.35, y: 0.3), startRadius: 1, endRadius: 18))
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().strokeBorder(model.flavor == f ? Color.primary : .clear, lineWidth: 2).padding(-3))
                                Text(f.name).font(Fonts.round(11))
                            }
                        }.buttonStyle(.plain).accessibilityLabel(Text("\(f.name) flavour"))
                    }
                }
                HStack { Button("Sample button") {}.buttonStyle(GumdropButtonStyle()); JellyBar(fraction: 0.62).frame(width: 180) }
                    .environment(\.flavor, model.flavor)
            }
            Section("Help") {
                Toggle("Balloon Help (hover to explain anything)", isOn: $model.balloonHelp)
            }
            Section("Alerts") {
                Stepper("Warn me when free space drops below \(Int(model.lowSpacePercent))%", value: $model.lowSpacePercent, in: 3...40, step: 1)
                Text("You'll also be told when one item grows more than 5 GB between scans.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                HStack {
                    Text(VolumeAccounting.hasFullDiskAccess() ? "Full Disk Access: on" : "Full Disk Access: off (optional)")
                    Spacer()
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ScanningSettings: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Project folders (for idle build folders and git worktrees)") {
                PathList(paths: $model.settings.projectRoots)
            }
            Section("Idle projects") {
                Stepper("A project is idle after \(model.settings.idleDays) days without edits or commits", value: $model.settings.idleDays, in: 3...180)
            }
            Section("Protected folders (never touched)") {
                PathList(paths: $model.settings.protectedPaths)
                Text("Sweep also never touches iCloud, Dropbox and OneDrive folders, Keychains, Mail and Messages data, or git worktrees with changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PathList: View {
    @Binding var paths: [String]
    var body: some View {
        ForEach(paths, id: \.self) { p in
            HStack {
                Text(p.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(role: .destructive) { paths.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
        }
        Button("Add folder…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
            if panel.runModal() == .OK { for u in panel.urls where !paths.contains(u.path) { paths.append(u.path) } }
        }
    }
}

struct MaintenanceSettings: View {
    @Environment(AppModel.self) var model
    @State private var showConsent = false
    var body: some View {
        Form {
            Section("Routine sweep") {
                if model.routineConsented {
                    Label("Approved. Routine sweeps only run the list you approved.", systemImage: "checkmark.seal").foregroundStyle(.green)
                } else if model.consent.hasAnyConsent {
                    Label("Paused: the list changed since you approved it.", systemImage: "pause.circle").foregroundStyle(.orange)
                } else {
                    Label("Off", systemImage: "circle")
                }
                HStack {
                    Button(model.routineConsented ? "Review the list…" : "Review and turn on…") { showConsent = true }
                    if model.routineConsented { Button("Turn off") { model.revokeRoutine() } }
                    Spacer()
                    Button("Run now") { model.runRoutineNow() }.disabled(!model.routineConsented || model.executing)
                }
            }
            Section("Schedule") {
                Toggle("Run the routine sweep weekly (Sundays at 10:00)", isOn: Binding(get: { model.scheduleInstalled }, set: { model.setSchedule($0) }))
                    .disabled(!model.routineConsented)
                Text("Uses a LaunchAgent. Each run posts a notification and writes a log to ~/Library/Logs/Sweep/.").font(.caption).foregroundStyle(.secondary)
                Button("Open log folder") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Sweep")
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
            }
            if let msg = model.maintenanceMessage { Section { Text(msg) } }
            if let run = model.lastRun {
                Section("Last run") {
                    Text("\(run.at.formatted()) · \(run.routine ? "routine" : "manual") · \(run.results.count) item(s)")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showConsent) { RoutineConsentSheet().environment(model).environment(\.flavor, model.flavor) }
    }
}

/// The one place a user turns on unattended cleanup. Every command is listed in plain words.
struct RoutineConsentSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    @Environment(\.dismiss) var dismiss
    @State private var understood = false
    var body: some View {
        let p = Palette.current(scheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MascotView(mood: .happy, size: 40)
                VStack(alignment: .leading) {
                    Text("Routine sweep: exactly what it does").font(Fonts.ui(20, .bold))
                    Text("Runs from the menu bar or weekly, without showing a plan first. It only ever does the things below.")
                        .font(Fonts.ui(13)).foregroundStyle(p.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.routineRules) { r in
                        let est = (model.report?.items ?? []).filter { $0.category == r.id }.reduce(Int64(0)) { $0 + $1.physicalBytes }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(r.title).font(Fonts.ui(15, .bold))
                                RebuildChip(cost: r.rebuildCost)
                                Spacer()
                                if est > 0 { Text("now ~\(ByteFormat.string(est))").font(Fonts.ui(13)).monospacedDigit() }
                            }
                            Text(r.explanation).font(Fonts.ui(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(command(r)).font(Fonts.mono(11))
                        }
                        Divider()
                    }
                }.padding(4)
            }
            .platinumWell()
            Text("Never included: AI model caches, Chrome's on-device model, Docker disk trimming, project folders, VMs, or anything that goes to the Trash. Items blocked at run time (for example while Xcode is open) are skipped and reported. If this list ever changes, routine sweeps pause until you approve it again.")
                .font(Fonts.ui(12)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("I understand what this removes", isOn: $understood).toggleStyle(.checkbox).font(Fonts.ui(14, .semibold))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PlatinumButtonStyle()).keyboardShortcut(.defaultAction)
                Button("Turn on routine sweeps") { model.acknowledgeRoutine(); dismiss() }
                    .buttonStyle(GumdropButtonStyle()).disabled(!understood)
            }
        }
        .padding(20).frame(width: 620, height: 600).background(p.chassis).foregroundStyle(p.text)
    }

    func command(_ r: Rule) -> String {
        switch r.action.type {
        case "tool": return "Runs: \(r.tool ?? "") \((r.action.command ?? []).joined(separator: " "))"
        case "hardDelete": return "Deletes: \((r.paths ?? []).joined(separator: ", "))"
        default:
            if r.kind == .docker { return "Runs: docker buildx prune -f --builder <each builder> (never containers or volumes)" }
            return r.action.type
        }
    }
}

struct InsightsSettings: View {
    @Environment(AppModel.self) var model
    @State private var key = ""
    @State private var saved = false
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Show AI insights on the dashboard", isOn: $model.insightsEnabled)
                Text("Off by default. Sweep works fully without it. The AI only explains a redacted summary; it never decides what gets deleted, never sees file contents and never runs commands.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider") {
                Picker("Provider", selection: $model.insightsProvider) {
                    ForEach(InsightsProviderKind.allCases) { Text($0.title).tag($0) }
                }
                switch model.insightsProvider {
                case .claudeCode:
                    Picker("Model", selection: $model.claudeCodeModel) {
                        Text("Sonnet (balanced)").tag("sonnet")
                        Text("Opus (most capable)").tag("opus")
                        Text("Haiku (fastest)").tag("haiku")
                        if !["sonnet", "opus", "haiku"].contains(model.claudeCodeModel) { Text(model.claudeCodeModel).tag(model.claudeCodeModel) }
                    }
                    if let path = model.claudeCodePath {
                        LabeledContent("Claude Code", value: path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        Text("Uses the account Claude Code is signed in with; no API key needed. Runs `claude -p` with no tools, no plugins, no MCP servers and no CLAUDE.md, in an empty folder, so it can only read the summary below.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(InsightsError.claudeCodeMissing.description).foregroundStyle(.orange)
                    }
                case .ollama:
                    if model.ollamaModels.isEmpty {
                        TextField("Ollama model", text: $model.ollamaModel)
                    } else {
                        Picker("Ollama model", selection: $model.ollamaModel) {
                            ForEach(model.ollamaModels, id: \.self) { Text($0).tag($0) }
                            if !model.ollamaModels.contains(model.ollamaModel) { Text(model.ollamaModel).tag(model.ollamaModel) }
                        }
                    }
                    Text("Talks to Ollama at 127.0.0.1:11434. Nothing leaves your Mac, unless you pick a model ending in -cloud, which Ollama runs on its servers. Small models (8B) often give vague answers; 14B or larger works better.")
                        .font(.caption).foregroundStyle(.secondary)
                case .anthropicAPI:
                    TextField("Model", text: $model.claudeModel)
                    SecureField(model.hasClaudeKey ? "API key (saved in Keychain)" : "API key", text: $key)
                    HStack {
                        Button("Save key") { model.saveClaudeKey(key); key = ""; saved = true }.disabled(key.isEmpty)
                        if model.hasClaudeKey { Button("Remove key") { model.saveClaudeKey(""); saved = false } }
                        if saved { Text("Saved to Keychain").foregroundStyle(.green) }
                    }
                }
                HStack {
                    Button("Check again") { model.refreshProviders() }
                    if let status = model.providerStatus { Text(status).font(.caption).foregroundStyle(.orange) }
                }
            }
            Section("Privacy") {
                Toggle("Send real project names (otherwise they become project_01, project_02…)", isOn: $model.settings.revealProjectNames)
                Text("Possible personal-data files are always fully redacted.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshProviders() }
        .onChange(of: model.insightsProvider) { model.refreshProviders() }
    }
}
