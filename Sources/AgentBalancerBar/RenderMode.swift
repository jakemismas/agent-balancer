import AppKit
import Core
import SwiftUI

/// The render flags of the app binary, run by scripts/render-views.sh and scripts/build-app.sh.
/// `--render <dir>` draws each view with `ImageRenderer` at 2x, light and dark, with the panel
/// material swapped for the flat token colors, and the README's first picture below a strip of
/// menu bar. `--iconset <dir>` draws the app icon sizes. Both
/// write only into a folder that `RenderOutput` accepts (under the current folder's `build`
/// folder, with no `..`, no link and no folder named `.claude` or `.agent-balancer` on its path
/// below the current folder, and outside the home's `.claude` and `.agent-balancer` folders,
/// each of which must be missing or a folder: a link to nothing stops the run, and so does a
/// HOME that is set but empty, is not an absolute path, or has a `..` segment), held open once
/// and written relative to its handle.
enum RenderMode {
    static func run(arguments: [String]) {
        guard
            let flagIndex = arguments.firstIndex(where: { $0 == "--render" || $0 == "--iconset" }),
            flagIndex + 1 < arguments.count
        else { fail("Usage: AgentBalancerBar --render <dir> or --iconset <dir>") }
        let writer: HeldFolder
        do {
            writer = try RenderOutput.hold(arguments[flagIndex + 1])
        } catch {
            fail(error.localizedDescription)
        }
        MainActor.assumeIsolated {
            do {
                if arguments[flagIndex] == "--render" {
                    try renderViews(writer)
                } else {
                    try renderIcons(writer)
                }
            } catch {
                fail("Render failed: \(error.localizedDescription)")
            }
        }
    }

    private static func fail(_ message: String) -> Never {
        print(message)
        exit(1)
    }

    @MainActor
    static func png<V: View>(_ view: V, scheme: ColorScheme, scale: CGFloat, flat: Bool = true)
        -> Data?
    {
        let styled = view.environment(\.colorScheme, scheme).environment(\.flatMaterials, flat)
        let renderer = ImageRenderer(content: styled)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    @MainActor
    private static func renderIcons(_ writer: HeldFolder) throws {
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let view = TileIcon().frame(width: CGFloat(size), height: CGFloat(size))
                guard let data = png(view, scheme: .light, scale: CGFloat(scale), flat: true) else {
                    throw ToolError("Could not draw the icon.")
                }
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                try writer.put(data, name: name)
            }
        }
    }

    @MainActor
    private static func renderViews(_ writer: HeldFolder) throws {
        LocalTime.zone = TimeZone(identifier: "America/Los_Angeles")!
        for (name, scene) in RenderScenes.all() {
            for scheme in [ColorScheme.light, .dark] {
                let backdrop = Palette.of(scheme).page
                let framed = scene.padding(16).background(backdrop)
                guard let data = png(framed, scheme: scheme, scale: 2) else {
                    throw ToolError("Could not draw \(name).")
                }
                let suffix = scheme == .dark ? "dark" : "light"
                try writer.put(data, name: "\(name)-\(suffix).png")
            }
        }
        for (name, scene) in ReadmeScenes.underBar() {
            for scheme in [ColorScheme.light, .dark] {
                guard let data = png(MenuBarFrame(content: scene), scheme: scheme, scale: 2) else {
                    throw ToolError("Could not draw \(name).")
                }
                let suffix = scheme == .dark ? "dark" : "light"
                try writer.put(data, name: "\(name)-\(suffix).png")
            }
        }
        let bar = MenuBarStrip()
        for scheme in [ColorScheme.light, .dark] {
            if let data = png(bar, scheme: scheme, scale: 2) {
                try writer.put(data, name: "menubar-\(scheme == .dark ? "dark" : "light").png")
            }
        }
    }
}

/// A panel open below a strip of menu bar on a plain desktop, as the menu shows when its icon is
/// clicked. The strip, the pressed icon and the desktop are framing that only the render tool
/// draws; the panel is the app's own view.
struct MenuBarFrame<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var scheme

    /// The app's menu bar icon, drawn first into an 8-bit sRGB bitmap at 2x: drawn as the image
    /// itself, it makes the renderer dither the whole picture.
    private var icon: Image {
        let side = 36
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let bitmap = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Image(nsImage: MenuIcon.image()) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        MenuIcon.image().draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let drawn = bitmap.makeImage() else { return Image(nsImage: MenuIcon.image()) }
        return Image(decorative: drawn, scale: 2)
    }

    var body: some View {
        let dark = scheme == .dark
        let ink: UInt32 = dark ? 0xFFFFFF : 0x000000
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                icon.renderingMode(.template).foregroundStyle(Palette.rgb(ink))
                    .frame(width: 30, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(Palette.rgb(ink, dark ? 0.16 : 0.12))
                    )
                    .padding(.trailing, 40)
            }
            .frame(height: 26)
            .background(Palette.rgb(0xFFFFFF, dark ? 0.06 : 0.55))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.rgb(ink, 0.08)).frame(height: 0.5)
            }
            content.padding(.top, 6).padding(.horizontal, 16).padding(.bottom, 16)
        }
        .background(Palette.of(scheme).page)
    }
}

/// The 18 point template icon on a bar, to see it in a light and a dark bar.
struct MenuBarStrip: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink: Color = scheme == .dark ? .white : .black
        HStack {
            Image(nsImage: MenuIcon.image()).renderingMode(.template).foregroundStyle(ink)
        }
        .padding(.horizontal, 10).frame(width: 60, height: 26)
        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.9))
    }
}
