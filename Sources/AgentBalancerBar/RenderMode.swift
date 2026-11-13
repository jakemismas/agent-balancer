import AppKit
import Core
import SwiftUI

/// The render flags of the app binary, run by scripts/render-views.sh and scripts/build-app.sh.
/// `--render <dir>` draws each view with `ImageRenderer` at 2x, light and dark, with the panel
/// material swapped for the flat token colors. `--iconset <dir>` draws the app icon sizes. Both
/// write through the no-follow writer and only into a folder under a `build` folder.
enum RenderMode {
    static func run(arguments: [String]) {
        guard
            let flagIndex = arguments.firstIndex(where: { $0 == "--render" || $0 == "--iconset" }),
            flagIndex + 1 < arguments.count
        else { fail("Usage: AgentBalancerBar --render <dir> or --iconset <dir>") }
        let dir = URL(fileURLWithPath: arguments[flagIndex + 1]).standardizedFileURL
        guard dir.path.contains("/build/") else { fail("The output folder must be under build/.") }
        let writer = NoFollowWriter(root: dir)
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
    private static func renderIcons(_ writer: NoFollowWriter) throws {
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let view = TileIcon().frame(width: CGFloat(size), height: CGFloat(size))
                guard let data = png(view, scheme: .light, scale: CGFloat(scale), flat: true) else {
                    throw ToolError("Could not draw the icon.")
                }
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                try writer.put(data, folders: [], name: name)
            }
        }
    }

    @MainActor
    private static func renderViews(_ writer: NoFollowWriter) throws {
        LocalTime.zone = TimeZone(identifier: "America/Los_Angeles")!
        for (name, scene) in RenderScenes.all() {
            for scheme in [ColorScheme.light, .dark] {
                let backdrop = Palette.of(scheme).page
                let framed = scene.padding(16).background(backdrop)
                guard let data = png(framed, scheme: scheme, scale: 2) else {
                    throw ToolError("Could not draw \(name).")
                }
                let suffix = scheme == .dark ? "dark" : "light"
                try writer.put(data, folders: [], name: "\(name)-\(suffix).png")
            }
        }
        let bar = MenuBarStrip()
        for scheme in [ColorScheme.light, .dark] {
            if let data = png(bar, scheme: scheme, scale: 2) {
                try writer.put(
                    data, folders: [], name: "menubar-\(scheme == .dark ? "dark" : "light").png")
            }
        }
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
