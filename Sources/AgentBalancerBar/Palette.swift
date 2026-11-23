import AppKit
import SwiftUI

/// The flat token colors of design/render.html, for light and dark.
struct Palette {
    let text1, text2, text3, sep, hover, accent, track, estimate, warn, warnInk, crit, good: Color
    let badgeBg, badgeMainBg, badgeMainInk, nextBg, panelBorder, cardBg, endsBg, errBg: Color
    let barStart, barEnd, nextBgEnd: Color
    /// Tokens rather than inline white, so the contrast test sees each text on the accent.
    let onAccent, onAccentSoft, onAccentBadge: Color
    /// The edge of each accent fill, since on a dark surface the fill alone reads under 3:1.
    let accentRing: Color
    /// Stands in for the panel material in the flat render: the panel token of design/render.html
    /// over the plain page backdrop. The running app draws no panel color of its own; the system
    /// material of its menu bar window shows.
    let flatPanel: Color
    let page: Color
    /// The Manage accounts window tokens of design/render.html.
    let winBg, winSide, winBar, fieldBg, fieldBorder, btnBg: Color

    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    var barFill: LinearGradient {
        LinearGradient(colors: [barStart, barEnd], startPoint: .leading, endPoint: .trailing)
    }

    var nextFill: LinearGradient {
        LinearGradient(colors: [nextBg, nextBgEnd], startPoint: .leading, endPoint: .trailing)
    }

    static let light = Palette(
        text1: rgb(0x19191A), text2: rgb(0x535358), text3: rgb(0x84848C),
        sep: rgb(0x000000, 0.09), hover: rgb(0x000000, 0.055), accent: rgb(0x7C3AED),
        track: rgb(0x7C3AED, 0.20), estimate: rgb(0x7C3AED, 0.75), warn: rgb(0xFAB219),
        warnInk: rgb(0x8A5A00), crit: rgb(0xD03B3B), good: rgb(0x0CA30C),
        badgeBg: rgb(0x000000, 0.06), badgeMainBg: rgb(0x7C3AED, 0.15),
        badgeMainInk: rgb(0x5B21B6), nextBg: rgb(0x7C3AED, 0.10), panelBorder: rgb(0x000000, 0.14),
        cardBg: rgb(0xF8F8FE), endsBg: rgb(0xFAB219, 0.18), errBg: rgb(0xD03B3B, 0.10),
        barStart: rgb(0x7C3AED), barEnd: rgb(0x2563EB), nextBgEnd: rgb(0x2563EB, 0.10),
        onAccent: rgb(0xFFFFFF), onAccentSoft: rgb(0xFFFFFF, 0.88),
        onAccentBadge: rgb(0xFFFFFF, 0.12), accentRing: rgb(0x7C3AED),
        flatPanel: rgb(0xF5F5FC), page: rgb(0xE8E9F6),
        winBg: rgb(0xF3F3FA), winSide: rgb(0xE6E7F2), winBar: rgb(0xE3E4EF), fieldBg: rgb(0xFFFFFF),
        fieldBorder: rgb(0x000000, 0.17), btnBg: rgb(0xFFFFFF))

    /// White text on the bars' violet here reads at 2.7:1, so text sits on light mode's violet.
    static let dark = Palette(
        text1: rgb(0xEEEFFA), text2: rgb(0xB5B5C0), text3: rgb(0x87878F),
        sep: rgb(0xFFFFFF, 0.09), hover: rgb(0xFFFFFF, 0.07), accent: rgb(0x7C3AED),
        track: rgb(0xA78BFA, 0.24), estimate: rgb(0xA78BFA, 0.85), warn: rgb(0xFAB219),
        warnInk: rgb(0xFAB219), crit: rgb(0xD03B3B), good: rgb(0x0CA30C),
        badgeBg: rgb(0xFFFFFF, 0.08), badgeMainBg: rgb(0xA78BFA, 0.20),
        badgeMainInk: rgb(0xC4B5FD), nextBg: rgb(0xA78BFA, 0.12), panelBorder: rgb(0xFFFFFF, 0.13),
        cardBg: rgb(0x1F1F20), endsBg: rgb(0xFAB219, 0.18), errBg: rgb(0xD03B3B, 0.10),
        barStart: rgb(0xA78BFA), barEnd: rgb(0x60A5FA), nextBgEnd: rgb(0x60A5FA, 0.12),
        onAccent: rgb(0xFFFFFF), onAccentSoft: rgb(0xFFFFFF, 0.88),
        onAccentBadge: rgb(0xFFFFFF, 0.12), accentRing: rgb(0xA78BFA),
        flatPanel: rgb(0x222223), page: rgb(0x141415),
        winBg: rgb(0x272728), winSide: rgb(0x1F1F20), winBar: rgb(0x313033), fieldBg: rgb(0x1A1A1B),
        fieldBorder: rgb(0xFFFFFF, 0.17), btnBg: rgb(0x39393A))

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
