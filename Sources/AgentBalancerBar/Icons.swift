import AppKit
import SwiftUI

/// The splitter tile of design/icons/splitter-tile-color.svg, drawn at any size.
struct TileIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 1024
            func rr(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
                Path(
                    roundedRect: CGRect(x: x * k, y: y * k, width: w * k, height: h * k),
                    cornerRadius: r * k, style: .continuous)
            }
            let gradient = Gradient(colors: [Palette.rgb(0xDE8160), Palette.rgb(0xB9583A)])
            ctx.fill(
                rr(100, 100, 824, 824, 185),
                with: .linearGradient(
                    gradient, startPoint: CGPoint(x: 0, y: 100 * k),
                    endPoint: CGPoint(x: 0, y: 924 * k)))
            let cream = Palette.rgb(0xFBF3E8)
            for r in [
                rr(290, 205, 150, 290, 34), rr(584, 205, 150, 290, 34),
                rr(437, 560, 150, 260, 34), rr(262, 455, 500, 150, 48),
            ] { ctx.fill(r, with: .color(cream)) }
            let ink = Palette.rgb(0xC4643F)
            for pts in [
                [(325.0, 345.0), (365, 305), (405, 345)], [(619, 345), (659, 305), (699, 345)],
                [(472, 745), (512, 705), (552, 745)],
            ] {
                var p = Path()
                p.move(to: CGPoint(x: pts[0].0 * k, y: pts[0].1 * k))
                p.addLine(to: CGPoint(x: pts[1].0 * k, y: pts[1].1 * k))
                p.addLine(to: CGPoint(x: pts[2].0 * k, y: pts[2].1 * k))
                ctx.stroke(
                    p, with: .color(ink),
                    style: StrokeStyle(lineWidth: 26 * k, lineCap: .round, lineJoin: .round))
            }
            for c in [(315.0, 530.0), (709, 530)] {
                let r = 17 * k
                ctx.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: c.0 * k - r, y: c.1 * k - r, width: 2 * r, height: 2 * r)),
                    with: .color(ink))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The menu bar template image of design/icons/splitter-tile-menu.svg: black plus alpha, 18 points.
enum MenuIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let shapes: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (3.22, 1, 3.9, 7.55, 0.89), (10.87, 1, 3.9, 7.55, 0.89),
                (7.05, 10.24, 3.9, 6.76, 0.89), (2.5, 7.5, 13, 3.9, 1.25),
            ]
            for s in shapes {
                NSBezierPath(
                    roundedRect: NSRect(x: s.0, y: s.1, width: s.2, height: s.3), xRadius: s.4,
                    yRadius: s.4
                ).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for cx in [3.95, 14.05] {
                NSBezierPath(ovalIn: NSRect(x: cx - 0.85, y: 9.45 - 0.85, width: 1.7, height: 1.7))
                    .fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
