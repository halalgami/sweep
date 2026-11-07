import AppKit
import CoreText
import SwiftUI

// MARK: - Flavours (iMac-era accent colours)

enum Flavor: String, CaseIterable, Identifiable, Codable {
    case blueberry, bondi, strawberry, tangerine, grape, lime
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var hex: UInt32 {
        switch self {
        case .blueberry: 0x2F7FD6
        case .bondi: 0x0A9BB8
        case .strawberry: 0xE2445C
        case .tangerine: 0xFF8A1F
        case .grape: 0x8A4FC7
        case .lime: 0x5FBF2F
        }
    }
    var color: Color { Color(hex: hex) }
    var light: Color { Color(hex: hex).mix(with: .white, by: 0.45) }
    var extraLight: Color { Color(hex: hex).mix(with: .white, by: 0.78) }
    var dark: Color { Color(hex: hex).mix(with: .black, by: 0.32) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    func mix(with other: Color, by t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .gray, b = NSColor(other).usingColorSpace(.sRGB) ?? .gray
        return Color(.sRGB, red: a.redComponent + (b.redComponent - a.redComponent) * t,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t)
    }
}

// MARK: - Platinum palette (light) and Graphite (dark)

struct Palette {
    var desk: Color, chassis: Color, panel: Color, well: Color, bevelLight: Color, bevelDark: Color
    var text: Color, secondary: Color, groove: Color, balloon: Color, balloonText: Color

    static func current(_ scheme: ColorScheme) -> Palette {
        scheme == .dark
            ? Palette(desk: Color(hex: 0x1E2026), chassis: Color(hex: 0x2B2D31), panel: Color(hex: 0x34363B), well: Color(hex: 0x1F2024),
                      bevelLight: Color(hex: 0x4A4D54), bevelDark: Color(hex: 0x17181B), text: Color(hex: 0xEDEDEF),
                      secondary: Color(hex: 0xA9ACB4), groove: Color(hex: 0x24262A), balloon: Color(hex: 0x4A4630), balloonText: Color(hex: 0xFFF6C8))
            : Palette(desk: Color(hex: 0xC9CDD6), chassis: Color(hex: 0xDCDCDC), panel: Color(hex: 0xE8E8E8), well: .white,
                      bevelLight: .white, bevelDark: Color(hex: 0x8A8A8A), text: Color(hex: 0x141414),
                      secondary: Color(hex: 0x4E535C), groove: Color(hex: 0x9B9B9B), balloon: Color(hex: 0xFFFFC6), balloonText: Color(hex: 0x1D1D10))
    }
}

// MARK: - Type

enum Fonts {
    static func register() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        if !urls.isEmpty { CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil) }
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        let name = weight == .bold || weight == .heavy ? "BarlowSemiCondensed-Bold"
            : weight == .semibold ? "BarlowSemiCondensed-SemiBold" : "BarlowSemiCondensed-Medium"
        return NSFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, weight: weight)
    }
    static func round(_ size: CGFloat) -> Font {
        NSFont(name: "VarelaRound-Regular", size: size) != nil ? .custom("VarelaRound-Regular", size: size) : .system(size: size, design: .rounded)
    }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

// MARK: - Environment

private struct FlavorKey: EnvironmentKey { static let defaultValue = Flavor.blueberry }
extension EnvironmentValues {
    var flavor: Flavor { get { self[FlavorKey.self] } set { self[FlavorKey.self] = newValue } }
}

// MARK: - Bevels, panels, wells

struct Bevel: View {
    var light: Color, dark: Color, inset: Bool, radius: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).strokeBorder(
                LinearGradient(colors: [inset ? dark : light, inset ? light : dark], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1)
        }
    }
}

struct PlatinumPanel: ViewModifier {
    @Environment(\.colorScheme) var scheme
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        let p = Palette.current(scheme)
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: 7).fill(p.panel))
            .overlay(Bevel(light: p.bevelLight, dark: p.bevelDark, inset: false, radius: 7))
    }
}

struct PlatinumWell: ViewModifier {
    @Environment(\.colorScheme) var scheme
    var padding: CGFloat = 8
    func body(content: Content) -> some View {
        let p = Palette.current(scheme)
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: 4).fill(p.well))
            .overlay(Bevel(light: p.bevelLight, dark: p.bevelDark, inset: true, radius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }
}

extension View {
    func platinumPanel(padding: CGFloat = 12) -> some View { modifier(PlatinumPanel(padding: padding)) }
    func platinumWell(padding: CGFloat = 8) -> some View { modifier(PlatinumWell(padding: padding)) }
}

/// Mac OS 8-style grooved stripes, tinted with the flavour.
struct Grooves: View {
    @Environment(\.flavor) var flavor
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let p = Palette.current(scheme)
        Canvas { ctx, size in
            var y: CGFloat = 1
            while y < size.height - 1 {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(p.bevelLight))
                ctx.fill(Path(CGRect(x: 0, y: y + 1, width: size.width, height: 1)), with: .color(flavor.light.opacity(scheme == .dark ? 0.5 : 0.9)))
                y += 3
            }
        }
    }
}

/// Section header: grooves with a label punched through, like a Platinum title bar.
struct GroovedHeader: View {
    @Environment(\.colorScheme) var scheme
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        let p = Palette.current(scheme)
        HStack(spacing: 8) {
            Grooves().frame(width: 14, height: 11)
            Text(title.uppercased()).font(Fonts.ui(12, .bold)).tracking(0.8).foregroundStyle(p.secondary).fixedSize()
            Grooves().frame(height: 11)
            if let trailing { trailing }
        }
    }
}

// MARK: - Gumdrop controls

struct GumdropButtonStyle: ButtonStyle {
    @Environment(\.flavor) var flavor
    @Environment(\.isEnabled) var enabled
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        let base = prominent ? flavor.color : Color(hex: 0xBFC3CA)
        configuration.label
            .font(Fonts.round(13))
            .foregroundStyle(prominent ? Color.white : Color(hex: 0x1C1F24))
            .shadow(color: .black.opacity(prominent ? 0.25 : 0), radius: 0, y: -0.5)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(
                Capsule().fill(LinearGradient(colors: [base.mix(with: .white, by: 0.6), base, base.mix(with: .white, by: 0.25)],
                                              startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0)], startPoint: .top, endPoint: .center))
                        .padding(.horizontal, 6).padding(.top, 1.5).padding(.bottom, 9))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1.5))
            .brightness(configuration.isPressed ? -0.12 : 0)
            .saturation(enabled ? 1 : 0.15)
            .opacity(enabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small Platinum push button for secondary actions.
struct PlatinumButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) var scheme
    func makeBody(configuration: Configuration) -> some View {
        let p = Palette.current(scheme)
        configuration.label.font(Fonts.ui(13, .semibold)).foregroundStyle(p.text)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [p.panel.mix(with: .white, by: scheme == .dark ? 0.08 : 0.5), p.chassis],
                                                                                 startPoint: .top, endPoint: .bottom)))
            .overlay(Bevel(light: p.bevelLight, dark: p.bevelDark, inset: configuration.isPressed, radius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.45), lineWidth: 0.6))
    }
}

/// Round jelly bar with gloss, spring overshoot and optional barber-pole stripes.
struct JellyBar: View {
    @Environment(\.flavor) var flavor
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var fraction: Double
    var striped = false
    var tint: Color? = nil
    var height: CGFloat = 14

    var body: some View {
        let p = Palette.current(scheme)
        let color = tint ?? flavor.color
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(p.well)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.4), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                Capsule()
                    .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.55), color, color.mix(with: .white, by: 0.2)], startPoint: .top, endPoint: .bottom))
                    .overlay(stripes(color).clipShape(Capsule()).opacity(striped ? 1 : 0))
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0)], startPoint: .top, endPoint: .center))
                        .padding(.horizontal, 4).padding(.top, 1).padding(.bottom, height * 0.5))
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                    .animation(reduceMotion ? .none : .spring(response: 0.7, dampingFraction: 0.55), value: fraction)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent"))
    }

    @ViewBuilder func stripes(_ color: Color) -> some View {
        TimelineView(.animation(paused: reduceMotion || !striped)) { tl in
            let phase = reduceMotion ? 0 : CGFloat(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.6) / 0.6) * 24
            Canvas { ctx, size in
                var x = -24 + phase - size.height
                while x < size.width + size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height)); path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    path.addLine(to: CGPoint(x: x + size.height + 10, y: 0)); path.addLine(to: CGPoint(x: x + 10, y: size.height))
                    ctx.fill(path, with: .color(.white.opacity(0.28)))
                    x += 24
                }
            }
        }
    }
}

/// A capsule split into coloured segments (APFS container, categories).
struct SegmentBar: View {
    struct Segment: Identifiable { let id: String; let color: Color; let value: Double }
    @Environment(\.colorScheme) var scheme
    var segments: [Segment]
    var height: CGFloat = 20
    var body: some View {
        let total = max(1, segments.reduce(0) { $0 + $1.value })
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(segments) { s in
                    Rectangle().fill(LinearGradient(colors: [s.color.mix(with: .white, by: 0.35), s.color], startPoint: .top, endPoint: .bottom))
                        .frame(width: geo.size.width * s.value / total)
                }
            }
            .overlay(LinearGradient(colors: [.white.opacity(0.5), .clear], startPoint: .top, endPoint: .center).padding(.bottom, height / 2))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.45), lineWidth: 0.7))
        }
        .frame(height: height)
        .background(Capsule().fill(Palette.current(scheme).well))
    }
}

/// Yellow help balloon, shown on hover when Balloon Help is on.
struct BalloonHelp: ViewModifier {
    @Environment(\.colorScheme) var scheme
    let text: String
    let enabled: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        let p = Palette.current(scheme)
        content
            .help(text)
            .onHover { hovering = $0 }
            .overlay(alignment: .topLeading) {
                if enabled && hovering {
                    Text(text).font(Fonts.round(12)).foregroundStyle(p.balloonText)
                        .padding(8).frame(maxWidth: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .background(RoundedRectangle(cornerRadius: 10).fill(p.balloon))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.6), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.25), radius: 0, x: 2, y: 2)
                        .offset(x: 12, y: -8).alignmentGuide(.top) { $0[.bottom] }
                        .allowsHitTesting(false).zIndex(10).transition(.opacity)
                }
            }
    }
}

/// Coloured chip used for tier/risk/rebuild labels (text always present; colour is never the only signal).
struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(Fonts.ui(11, .bold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .background(Capsule().fill(color))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }
}
