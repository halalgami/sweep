import SwiftUI

/// Sweep's mascot: an original 12×13 pixel trash can. Mood follows free space.
enum MascotMood { case happy, nervous, sweating, asleep, working }

struct MascotView: View {
    @Environment(\.flavor) var flavor
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var mood: MascotMood
    var hopTrigger: Int = 0
    var size: CGFloat = 52
    @State private var hop = false

    static let base = ["....####....", ".##########.", "############", "............", ".##########.", ".#........#."]
    var face: [String] {
        switch mood {
        case .happy, .working: [".#.##..##.#.", ".#.##..##.#.", ".#........#.", ".#.#....#.#.", ".#..####..#."]
        case .nervous: [".#.##..##.#.", ".#.##..##.#.", ".#........#.", ".#........#.", ".#..####..#."]
        case .sweating: [".#.##..##.#.", ".#.##..##.#.", ".#........#.", ".#...##...#.", ".#..#..#..#."]
        case .asleep: [".#........#.", ".#.##..##.#.", ".#........#.", ".#........#.", ".#...##...#."]
        }
    }
    var rows: [String] { Self.base + face + [".#........#.", "..########.."] }

    var body: some View {
        let ink = scheme == .dark ? Color(hex: 0x0E1016) : Color(hex: 0x15192A)
        Canvas { ctx, sz in
            let px = sz.width / 12
            ctx.fill(Path(CGRect(x: 2 * px, y: 5 * px, width: 8 * px, height: 7 * px)), with: .color(flavor.extraLight))
            for (y, row) in rows.enumerated() {
                for (x, c) in row.enumerated() where c == "#" {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px + 0.3, height: px + 0.3)), with: .color(ink))
                }
            }
            if mood == .sweating {
                ctx.fill(Path(CGRect(x: 11 * px, y: 4 * px, width: px, height: px * 1.5)), with: .color(Color(hex: 0x7FD6FF)))
            }
            if mood == .asleep {
                ctx.draw(Text("z").font(.system(size: px * 3, weight: .heavy)).foregroundColor(flavor.color), at: CGPoint(x: 11.5 * px, y: 0.5 * px))
            }
        }
        .frame(width: size, height: size * 13 / 12)
        .scaleEffect(x: hop ? 0.92 : 1, y: hop ? 1.08 : 1, anchor: .bottom)
        .offset(y: hop ? -size * 0.25 : 0)
        .onChange(of: hopTrigger) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { hop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.45)) { hop = false }
            }
        }
        .accessibilityLabel(Text("Sweep mascot, \(String(describing: mood))"))
    }

    static func mood(freeFraction: Double, hasWork: Bool) -> MascotMood {
        if freeFraction < 0.05 { return .sweating }
        if freeFraction < 0.10 { return .nervous }
        return hasWork ? .happy : .asleep
    }
}

/// Speech bubble next to the mascot.
struct SpeechBubble: View {
    @Environment(\.colorScheme) var scheme
    let text: String
    var body: some View {
        let p = Palette.current(scheme)
        Text(text).font(Fonts.round(13)).foregroundStyle(p.balloonText)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(p.balloon))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.55), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.22), radius: 0, x: 2, y: 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
