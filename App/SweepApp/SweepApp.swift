import SwiftUI
import SweepCore

@main
struct SweepApp: App {
    @State private var model: AppModel

    init() {
        Fonts.register()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("Sweep", id: "main") {
            RootView()
                .environment(model)
                .environment(\.flavor, model.flavor)
                .frame(minWidth: 940, minHeight: 680)
                .onAppear {
                    model.requestNotificationPermission()
                    if model.report == nil { model.scan() }
                }
        }
        .defaultSize(width: 1120, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Sweep") {
                Button("Scan Again") { model.scan() }.keyboardShortcut("r")
                Button("Review Safe Sweep…") { model.openPlan() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.report == nil || model.scanning)
                Toggle("Balloon Help", isOn: Binding(get: { model.balloonHelp }, set: { model.balloonHelp = $0 }))
                    .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView().environment(model).environment(\.flavor, model.flavor)
        } label: {
            Label("\(Int((Double(model.volume.freeBytes) / 1e9).rounded())) GB", systemImage: "trash")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model).environment(\.flavor, model.flavor)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme

    var body: some View {
        let p = Palette.current(scheme)
        VStack(spacing: 0) {
            TopBar()
            Group {
                switch model.screen {
                case .dashboard: DashboardView()
                case .plan: PlanView()
                case .execute: ExecuteView()
                case .verify: VerifyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(p.desk)
        .foregroundStyle(p.text)
        .sheet(item: Binding(get: { model.selectedItem }, set: { model.selectedItem = $0 })) { item in
            ItemDetailSheet(item: item).environment(model).environment(\.flavor, model.flavor)
        }
    }
}

/// Platinum-style strip across the top with the main actions.
struct TopBar: View {
    @Environment(AppModel.self) var model
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let p = Palette.current(scheme)
        HStack(spacing: 12) {
            Text("Sweep").font(Fonts.ui(20, .bold))
            Grooves().frame(height: 13)
            if model.scanning {
                ProgressView().controlSize(.small)
                Button("Stop") { model.cancelScan() }.buttonStyle(PlatinumButtonStyle())
            } else if model.screen == .dashboard {
                Button { model.scan() } label: { Label("Scan", systemImage: "arrow.clockwise") }
                    .buttonStyle(PlatinumButtonStyle())
                    .modifier(BalloonHelp(text: "Measure everything again. Scanning never changes anything.", enabled: model.balloonHelp))
            }
            Toggle(isOn: Binding(get: { model.balloonHelp }, set: { model.balloonHelp = $0 })) {
                Image(systemName: "questionmark.bubble")
            }
            .toggleStyle(.button)
            .help("Balloon Help: hover anything to see what it means")
            SettingsLink { Image(systemName: "gearshape") }.buttonStyle(PlatinumButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(LinearGradient(colors: [p.chassis.mix(with: .white, by: scheme == .dark ? 0.05 : 0.5), p.chassis], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Rectangle().fill(p.bevelDark).frame(height: 1) }
    }
}
