import AppKit
import SwiftUI

/// The flat token colors of design/render.html, for light and dark.
struct Palette {
    let text1, text2, text3, sep, hover, accent, track, estimate, warn, warnInk, crit, good: Color
    let badgeBg, badgeMainBg, badgeMainInk, nextBg, panelBorder, cardBg, endsBg, errBg: Color
    /// Stands in for the panel material in the flat render.
    let flatPanel: Color
    let page: Color
    /// The Manage accounts window tokens of design/render.html.
    let winBg, winSide, winBar, fieldBg, fieldBorder, btnBg: Color

    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    static let light = Palette(
        text1: rgb(0x1C1916), text2: rgb(0x5A524B), text3: rgb(0x8B837B),
        sep: rgb(0x000000, 0.09), hover: rgb(0x000000, 0.055), accent: rgb(0xC4613D),
        track: rgb(0xC4613D, 0.20), estimate: rgb(0xC4613D, 0.75), warn: rgb(0xFAB219),
        warnInk: rgb(0x8A5A00), crit: rgb(0xD03B3B), good: rgb(0x0CA30C),
        badgeBg: rgb(0x000000, 0.06), badgeMainBg: rgb(0xC4613D, 0.15),
        badgeMainInk: rgb(0x94431F), nextBg: rgb(0xC4613D, 0.10), panelBorder: rgb(0x000000, 0.14),
        cardBg: rgb(0xFBF8F4), endsBg: rgb(0xFAB219, 0.18), errBg: rgb(0xD03B3B, 0.10),
        flatPanel: rgb(0xF8EAE2), page: rgb(0xEFE9E2),
        winBg: rgb(0xF6F3EE), winSide: rgb(0xECE7E0), winBar: rgb(0xE9E4DD), fieldBg: rgb(0xFFFFFF),
        fieldBorder: rgb(0x000000, 0.17), btnBg: rgb(0xFFFFFF))

    static let dark = Palette(
        text1: rgb(0xF4EFE9), text2: rgb(0xBDB4AB), text3: rgb(0x8F867E),
        sep: rgb(0xFFFFFF, 0.09), hover: rgb(0xFFFFFF, 0.07), accent: rgb(0xE57D55),
        track: rgb(0xE57D55, 0.24), estimate: rgb(0xE57D55, 0.85), warn: rgb(0xFAB219),
        warnInk: rgb(0xFAB219), crit: rgb(0xD03B3B), good: rgb(0x0CA30C),
        badgeBg: rgb(0xFFFFFF, 0.08), badgeMainBg: rgb(0xE57D55, 0.20),
        badgeMainInk: rgb(0xF2A385), nextBg: rgb(0xE57D55, 0.12), panelBorder: rgb(0xFFFFFF, 0.13),
        cardBg: rgb(0x221E1B), endsBg: rgb(0xFAB219, 0.18), errBg: rgb(0xD03B3B, 0.10),
        flatPanel: rgb(0x2B2320), page: rgb(0x171412),
        winBg: rgb(0x2A2623), winSide: rgb(0x221F1C), winBar: rgb(0x34302C), fieldBg: rgb(0x1D1A18),
        fieldBorder: rgb(0xFFFFFF, 0.17), btnBg: rgb(0x3D3834))

    static func of(_ scheme: ColorScheme) -> Palette { scheme == .dark ? dark : light }
}

private struct FlatKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True in the render tool: materials are swapped for the flat token colors.
    var flatMaterials: Bool {
        get { self[FlatKey.self] }
        set { self[FlatKey.self] = newValue }
    }
}

extension Font {
    /// The system font at a fixed size, or its monospaced form.
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular, mono: Bool = false) -> Font
    {
        Font(
            mono
                ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight))
    }
}
