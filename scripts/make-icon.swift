// Draws Sweep's app icon (original pixel trash-can mascot on a glossy blueberry gumdrop) to a 1024px PNG.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let body = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
// shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(red: 0.18, green: 0.50, blue: 0.84, alpha: 1).setFill()
body.fill()
ctx.restoreGState()
// candy gradient
NSGradient(colors: [NSColor(red: 0.55, green: 0.78, blue: 1, alpha: 1), NSColor(red: 0.16, green: 0.47, blue: 0.82, alpha: 1),
                    NSColor(red: 0.30, green: 0.62, blue: 0.95, alpha: 1)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: -90)
// gloss
let gloss = NSBezierPath(roundedRect: CGRect(x: rect.minX + 40, y: rect.midY + 40, width: rect.width - 80, height: rect.height / 2 - 70), xRadius: 150, yRadius: 150)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0.05)])!.draw(in: gloss, angle: -90)
// sprite
let sprite = ["....####....", ".##########.", "############", "............", ".##########.", ".#........#.", ".#.##..##.#.",
              ".#.##..##.#.", ".#........#.", ".#.#....#.#.", ".#..####..#.", ".#........#.", "..########.."]
let px: CGFloat = 40
let ox = (size - 12 * px) / 2, oy = (size - 13 * px) / 2 - 20
NSColor(white: 0.97, alpha: 1).setFill()
NSBezierPath(rect: CGRect(x: ox + 2 * px, y: oy + (13 - 12) * px, width: 8 * px, height: 7 * px)).fill()
NSColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 1).setFill()
for (y, row) in sprite.enumerated() {
    for (x, c) in row.enumerated() where c == "#" {
        NSBezierPath(rect: CGRect(x: ox + CGFloat(x) * px, y: oy + CGFloat(12 - y) * px, width: px, height: px)).fill()
    }
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
