import CoreGraphics
import Foundation
import ImageIO
import Testing

/// A color in sRGB with each part from 0 to 1 and straight alpha.
struct RGBA: CustomStringConvertible {
    var r, g, b, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255, a: alpha)
    }

    /// How far the color is from a gray, whatever its lightness.
    var chroma: Double { max(r, g, b) - min(r, g, b) }

    /// The HSB saturation: the share of the brightest part that is tint.
    var saturation: Double { max(r, g, b) > 0 ? chroma / max(r, g, b) : 0 }

    /// The hue in degrees, from 0 up to 360; 0 for a gray.
    var hue: Double {
        let top = max(r, g, b)
        guard chroma > 0 else { return 0 }
        let sector: Double
        if top == r {
            sector = (g - b) / chroma
        } else if top == g {
            sector = (b - r) / chroma + 2
        } else {
            sector = (r - g) / chroma + 4
        }
        let degrees = sector * 60
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// The WCAG 2 relative luminance.
    var luminance: Double {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Whether each part is within one and a half 8-bit steps of `other`'s.
    func isNear(_ other: RGBA) -> Bool {
        [r - other.r, g - other.g, b - other.b].allSatisfy { abs($0) < 1.5 / 255 }
    }

    /// This color drawn over an opaque one.
    func over(_ under: RGBA) -> RGBA {
        RGBA(
            r: r * a + under.r * (1 - a), g: g * a + under.g * (1 - a),
            b: b * a + under.b * (1 - a))
    }

    /// The color `t` of the way from this one to `end`, as a gradient between them draws it.
    func toward(_ end: RGBA, _ t: Double) -> RGBA {
        RGBA(
            r: r + (end.r - r) * t, g: g + (end.g - g) * t, b: b + (end.b - b) * t,
            a: a + (end.a - a) * t)
    }

    static func contrast(_ x: RGBA, _ y: RGBA) -> Double {
        let (light, dark) = (max(x.luminance, y.luminance), min(x.luminance, y.luminance))
        return (light + 0.05) / (dark + 0.05)
    }

    var description: String {
        let parts = [r, g, b].map { String(format: "%02X", Int(($0 * 255).rounded())) }
        return "#" + parts.joined() + (a < 1 ? " at \(a)" : "")
    }
}

/// The violet to blue scheme, read from the palette, the icon, the design file and drawn views.
@Suite struct ColorSchemeTests {
    /// The accent and the tokens made from it, named so the amber warning is never held to them.
    static let accentTokens = [
        "accent", "track", "estimate", "badgeMainBg", "badgeMainInk", "nextBg", "nextBgEnd",
        "barStart", "barEnd", "accentRing",
    ]

    /// Hue from 10 to 50 degrees; under chroma 0.15 a color reads as a tinted gray, not orange.
    static func isOrange(_ color: RGBA) -> Bool {
        color.chroma >= 0.15 && color.hue >= 10 && color.hue <= 50
    }

    /// Violet or blue: a hue from 200 to 290 degrees with a visible chroma.
    static func isVioletOrBlue(_ color: RGBA) -> Bool {
        color.chroma >= 0.15 && color.hue >= 200 && color.hue <= 290
    }

    /// The warning, critical and good tokens, which keep their own hues.
    static let statusTokens = ["warn", "warnInk", "endsBg", "crit", "errBg", "good"]

    /// A gray, or from 1% HSB saturation (a tint starts to show) hue 220 to 270 at 6% or less.
    static func isCoolNeutral(_ color: RGBA) -> Bool {
        let s = color.saturation
        return s < 0.01 || (s <= 0.06 && color.hue >= 220 && color.hue <= 270)
    }

    static func hueDistance(_ x: RGBA, _ y: RGBA) -> Double {
        let gap = abs(x.hue - y.hue)
        return min(gap, 360 - gap)
    }

    /// The text between the parenthesis that ends `marker` and the one that closes it.
    static func parenthesized(after marker: String, in text: String) -> String? {
        guard let found = text.range(of: marker) else { return nil }
        var depth = 1
        var index = found.upperBound
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return String(text[found.upperBound..<index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The names of the color tokens Palette declares.
    static func declaredTokens() throws -> Set<String> {
        var names: Set<String> = []
        for line in try AppSurfaceTests.source("Palette.swift").split(separator: "\n") {
            guard let match = line.wholeMatch(of: /\ {4}let ([A-Za-z0-9, ]+): Color/) else {
                continue
            }
            for name in match.output.1.split(separator: ",") {
                names.insert(name.trimmingCharacters(in: .whitespaces))
            }
        }
        return names
    }

    /// `Palette.light` or `.dark` as written; a token in another form goes unread and fails here.
    static func palette(_ mode: String) throws -> [String: RGBA] {
        let text = try AppSurfaceTests.source("Palette.swift")
        let call = try #require(parenthesized(after: "static let \(mode) = Palette(", in: text))
        var tokens: [String: RGBA] = [:]
        for match in call.matches(of: /(\w+): rgb\(0x([0-9A-Fa-f]{6})(?:, ([0-9.]+))?\)/) {
            let hex = try #require(UInt32(match.output.2, radix: 16))
            let alpha = try match.output.3.map { try #require(Double($0)) } ?? 1
            tokens[String(match.output.1)] = RGBA(hex: hex, alpha: alpha)
        }
        let declared = try declaredTokens()
        #expect(declared.count > 20)
        #expect(Set(tokens.keys) == declared, "\(mode)")
        return tokens
    }

    static func token(_ tokens: [String: RGBA], _ name: String, _ mode: String) throws -> RGBA {
        try #require(tokens[name], "\(mode) has no \(name) token")
    }

    @Test func noAccentTokenIsOrangeAndEveryNeutralIsCoolInEitherMode() throws {
        let declared = try Self.declaredTokens()
        let neutrals = declared.subtracting(Self.accentTokens).subtracting(Self.statusTokens)
        #expect(neutrals.count >= 16, "\(neutrals.sorted())")
        for mode in ["light", "dark"] {
            let tokens = try Self.palette(mode)
            // Every token but the accents and the status colors: the text, surfaces and lines.
            for name in neutrals.sorted() {
                let color = try Self.token(tokens, name, mode)
                #expect(Self.isCoolNeutral(color), "\(mode) \(name) \(color) is not a cool neutral")
            }
            for name in Self.accentTokens {
                let color = try Self.token(tokens, name, mode)
                #expect(!Self.isOrange(color), "\(mode) \(name) \(color) is orange")
                #expect(Self.isVioletOrBlue(color), "\(mode) \(name) \(color)")
            }
            // The gradient runs from violet to blue, on the bars and on the next pick's tint.
            for (start, end) in [("barStart", "barEnd"), ("nextBg", "nextBgEnd")] {
                let from = try Self.token(tokens, start, mode)
                let to = try Self.token(tokens, end, mode)
                #expect(from.hue >= 245, "\(mode) \(start) \(from)")
                #expect(to.hue <= 235, "\(mode) \(end) \(to)")
            }
        }
    }

    /// The tile's two gradient stops, then the face and the line work, as Icons.swift draws them.
    static func tileColors() throws -> [UInt32] {
        let text = try AppSurfaceTests.source("Icons.swift")
        let tile = try #require(AppSurfaceTests.block(after: "struct TileIcon: View", in: text))
        return try tile.matches(of: /Palette\.rgb\(0x([0-9A-Fa-f]{6})\)/).map {
            try #require(UInt32($0.output.1, radix: 16))
        }
    }

    @Test func theIconTileRunsFromVioletToBlueInTheAppAndItsDesignFile() throws {
        let colors = try Self.tileColors()
        try #require(colors.count == 4, "\(colors)")
        let (top, bottom) = (RGBA(hex: colors[0]), RGBA(hex: colors[1]))
        let (face, ink) = (RGBA(hex: colors[2]), RGBA(hex: colors[3]))
        for color in [top, bottom, face, ink] { #expect(!Self.isOrange(color), "\(color)") }
        #expect(Self.isVioletOrBlue(top) && top.hue >= 245, "\(top)")
        #expect(Self.isVioletOrBlue(bottom) && bottom.hue <= 235, "\(bottom)")
        #expect(Self.isCoolNeutral(face), "\(face)")
        // The line work reads as the tile seen through the face.
        #expect(Self.isVioletOrBlue(ink), "\(ink)")
        #expect(RGBA.contrast(ink, face) >= 3, "\(ink) on \(face)")
        let svg = try String(
            contentsOf: Support.root.appendingPathComponent("design/icons/splitter-tile-color.svg"),
            encoding: .utf8)
        var drawn: [UInt32] = []
        for match in svg.matches(of: /#([0-9A-Fa-f]{6})/) {
            let hex = try #require(UInt32(match.output.1, radix: 16))
            if !drawn.contains(hex) { drawn.append(hex) }
        }
        #expect(drawn == colors, "the design file and Icons.swift differ")
        // Every paint in the design file is one of those colors, the tile's gradient or none.
        let allowed = Set(colors.map { String(format: "#%06X", $0) } + ["URL(#TILE)", "NONE"])
        let paints = svg.matches(of: /(fill|stroke|stop-color|color)\s*=\s*["']([^"']*)["']/)
        #expect(paints.count >= 7)
        for paint in paints {
            let value = String(paint.output.2)
            #expect(allowed.contains(value.uppercased()), "\(paint.output.1)=\"\(value)\"")
        }
        #expect(!svg.contains("style"), "a style attribute or element can paint any color")
    }

    /// The custom properties of every rule for `selector` in design/render.html, later ones last.
    static func cssTokens(_ selector: String) throws -> [String: String] {
        let text = try String(
            contentsOf: Support.root.appendingPathComponent("design/render.html"), encoding: .utf8)
        var out: [String: String] = [:]
        var rest = Substring(text)
        var rules = 0
        while let found = rest.range(of: "\n  " + selector + " {") {
            let rule = String(rest[found.lowerBound...])
            let block = try #require(AppSurfaceTests.block(after: "\n  " + selector, in: rule))
            for match in block.matches(of: /--([a-z0-9-]+):\s*([^;]+);/) {
                out[String(match.output.1)] = String(match.output.2)
            }
            rest = rest[found.upperBound...]
            rules += 1
        }
        #expect(rules == 2, "\(selector)")
        return out
    }

    /// Each color a CSS value names, in hex or `rgba()`.
    static func cssColors(_ value: String) throws -> [RGBA] {
        var out: [RGBA] = []
        for match in value.matches(of: /#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b/) {
            var digits = String(match.output.1)
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            out.append(RGBA(hex: try #require(UInt32(digits, radix: 16))))
        }
        for match in value.matches(of: /rgba\((\d+), (\d+), (\d+), ([0-9.]+)\)/) {
            let parts = try [match.output.1, match.output.2, match.output.3].map {
                try #require(Double($0)) / 255
            }
            let alpha = try #require(Double(match.output.4))
            out.append(RGBA(r: parts[0], g: parts[1], b: parts[2], a: alpha))
        }
        return out
    }

    @Test func theDesignReferenceCarriesTheAppsTokensAndItsOwnNeutralsAreCool() throws {
        let light = try Self.cssTokens(":root")
        let dark = light.merging(try Self.cssTokens(":root[data-theme=\"dark\"]")) { $1 }
        let shared = [
            ("accent", "accent"), ("track", "track"), ("estimate", "estimate"),
            ("badge-main-bg", "badgeMainBg"), ("badge-main-ink", "badgeMainInk"),
            ("next-bg", "nextBg"), ("next-bg-end", "nextBgEnd"), ("bar-start", "barStart"),
            ("bar-end", "barEnd"), ("on-accent", "onAccent"), ("on-accent-soft", "onAccentSoft"),
            ("on-accent-badge", "onAccentBadge"), ("accent-ring", "accentRing"),
            ("text-1", "text1"), ("text-2", "text2"),
            ("text-3", "text3"), ("sep", "sep"), ("hover", "hover"), ("badge-bg", "badgeBg"),
            ("panel-border", "panelBorder"), ("card-bg", "cardBg"), ("page-bg", "page"),
            ("win-bg", "winBg"), ("win-side", "winSide"), ("win-bar", "winBar"),
            ("field-bg", "fieldBg"), ("field-border", "fieldBorder"), ("btn-bg", "btnBg"),
        ]
        let pageOnly = [
            "page-text", "page-text-2", "menubar-bg", "menubar-text", "menubar-pressed",
            "panel-bg", "line-mark",
        ]
        for (mode, css) in [("light", light), ("dark", dark)] {
            let tokens = try Self.palette(mode)
            func color(_ property: String) throws -> RGBA {
                let value = try #require(css[property], "\(mode) --\(property)")
                let colors = try Self.cssColors(value)
                try #require(colors.count == 1, "\(mode) --\(property): \(value)")
                return colors[0]
            }
            // The page's own text, its menu bar and the panel are cool neutrals too.
            for property in pageOnly {
                let neutral = try color(property)
                #expect(Self.isCoolNeutral(neutral), "\(mode) --\(property) \(neutral)")
            }
            // The flat render's panel is the design's panel over its page, within one 8-bit step.
            let flat = try color("panel-bg").over(color("page-bg"))
            let panel = try Self.token(tokens, "flatPanel", mode)
            let gap = [flat.r - panel.r, flat.g - panel.g, flat.b - panel.b].map { abs($0) * 255 }
            #expect(gap.allSatisfy { $0 <= 1 }, "\(mode) flatPanel \(panel) against \(flat)")
            for (property, name) in shared {
                let (design, app) = (try color(property), try Self.token(tokens, name, mode))
                let off = [design.r - app.r, design.g - app.g, design.b - app.b, design.a - app.a]
                #expect(
                    off.allSatisfy { abs($0) < 0.001 },
                    "\(mode) --\(property) \(design) differs from \(name) \(app)")
            }
        }
    }

    /// A gray, or a violet to blue hue at any strength.
    static func isGrayOrVioletToBlue(_ color: RGBA) -> Bool {
        color.saturation < 0.01 || (color.hue >= 200 && color.hue <= 290)
    }

    /// What a CSS value holds besides hex and `rgba()` colors and sizes, such as a named color.
    static func cssLeftover(_ value: String) -> [String] {
        var rest = value.replacing(/#[0-9a-fA-F]{3,8}/, with: " ")
        rest = rest.replacing(/rgba\(\d+, \d+, \d+, [0-9.]+\)/, with: " ")
        rest = rest.replacing(/-?[0-9.]+(px|%)?/, with: " ")
        let words = rest.split { !($0.isLetter || $0 == "-") }.map(String.init)
        return words.filter { !["radial-gradient", "at"].contains($0) }
    }

    @Test func theDesignReferencesDesktopShadowAndBordersAreGrayOrVioletToBlue() throws {
        let light = try Self.cssTokens(":root")
        let dark = light.merging(try Self.cssTokens(":root[data-theme=\"dark\"]")) { $1 }
        for (mode, css) in [("light", light), ("dark", dark)] {
            // The desktop picture and the shadow and borders over it were orange and brown.
            for property in ["wall", "panel-shadow", "card-border"] {
                let value = try #require(css[property], "\(mode) --\(property)")
                #expect(Self.cssLeftover(value).isEmpty, "\(mode) --\(property): \(value)")
                let colors = try Self.cssColors(value)
                #expect(!colors.isEmpty, "\(mode) --\(property)")
                for color in colors {
                    #expect(
                        Self.isGrayOrVioletToBlue(color), "\(mode) --\(property) holds \(color)")
                }
            }
        }
    }

    /// The declarations of the one rule for `selector` in design/render.html.
    static func cssRule(_ selector: String) throws -> String {
        let text = try String(
            contentsOf: Support.root.appendingPathComponent("design/render.html"), encoding: .utf8)
        let found = try #require(text.range(of: "\n  " + selector + " {"), "\(selector)")
        #expect(text.components(separatedBy: "\n  " + selector + " {").count == 2, "\(selector)")
        let rule = String(text[found.lowerBound...])
        return try #require(
            AppSurfaceTests.block(after: "\n  " + selector, in: rule), "\(selector)")
    }

    @Test func theDesignReferenceDrawsItsGradientsAndAccentRingsWithTheirTokens() throws {
        let gradients = [
            (".next", "linear-gradient(90deg, var(--next-bg), var(--next-bg-end))"),
            (".meter .fill", "linear-gradient(90deg, var(--bar-start), var(--bar-end))"),
        ]
        for (selector, gradient) in gradients {
            let rule = try Self.cssRule(selector)
            let declarations = rule.dropFirst().dropLast().split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let backgrounds = declarations.filter { $0.hasPrefix("background") }
            #expect(backgrounds == ["background: " + gradient], "\(selector): \(rule)")
        }
        // Each mock of a control on the accent carries the ring the app draws at its edge.
        let ringed = [
            ".act:hover", ".acct[aria-selected=\"true\"]", ".btn.primary", ".radio .rb.on",
            ".seg button[aria-pressed=\"true\"]",
        ]
        for selector in ringed {
            let rule = try Self.cssRule(selector)
            #expect(rule.contains("var(--accent-ring)"), "\(selector): \(rule)")
        }
    }

    @Test func theWarningCriticalAndGoodColorsKeepTheirHuesSixtyDegreesFromTheAccent() throws {
        for mode in ["light", "dark"] {
            let tokens = try Self.palette(mode)
            let accents = try Self.accentTokens.map { try Self.token(tokens, $0, mode) }
            let bands: [(String, (Double) -> Bool)] = [
                ("warn", { (35...50).contains($0) }), ("warnInk", { (35...50).contains($0) }),
                ("endsBg", { (35...50).contains($0) }), ("crit", { $0 <= 10 || $0 >= 350 }),
                ("errBg", { $0 <= 10 || $0 >= 350 }), ("good", { (90...150).contains($0) }),
            ]
            for (name, inBand) in bands {
                let color = try Self.token(tokens, name, mode)
                #expect(color.chroma >= 0.3 && inBand(color.hue), "\(mode) \(name) \(color)")
                for (accent, accentName) in zip(accents, Self.accentTokens) {
                    let distance = Self.hueDistance(color, accent)
                    #expect(distance >= 60, "\(mode) \(name) is \(distance) from \(accentName)")
                }
            }
        }
    }

    /// Each text on an accent surface, with the surface composited as the flat render draws it.
    static func textOnAccent(_ mode: String) throws -> [(String, RGBA, RGBA)] {
        let tokens = try palette(mode)
        func t(_ name: String) throws -> RGBA { try token(tokens, name, mode) }
        let panel = try t("flatPanel")
        var pairs: [(String, RGBA, RGBA)] = []
        // The main badge in a menu row, hovered or not, and in the window's list and header.
        let unders = try [
            ("panel", panel), ("hovered row", t("hover").over(panel)),
            ("window list", t("winSide")), ("window", t("winBg")),
        ]
        for (place, under) in unders {
            let badge = try t("badgeMainBg").over(under)
            pairs.append(("main badge on the \(place)", try t("badgeMainInk"), badge))
        }
        // A stale row dims all but its main badge, which sits on the row's dimmed hover.
        var hover = try t("hover")
        hover.a *= try staleDim()
        let staleBadge = try t("badgeMainBg").over(hover.over(panel))
        pairs.append(("main badge on a hovered stale row", try t("badgeMainInk"), staleBadge))
        // The next pick and the empty-state cards, along their gradient.
        for step in 0...10 {
            let tint = try t("nextBg").toward(t("nextBgEnd"), Double(step) / 10).over(panel)
            for ink in ["text1", "text2"] {
                pairs.append(("\(ink) on the next pick at \(step * 10)%", try t(ink), tint))
            }
        }
        // A selected account, a primary button and a hovered action, and a selected main badge.
        let accent = try t("accent").over(panel)
        let badge = try t("onAccentBadge").over(accent)
        try pairs.append(("text on the accent", t("onAccent"), accent))
        try pairs.append(("second line on the accent", t("onAccentSoft"), accent))
        try pairs.append(("selected main badge", t("onAccent"), badge))
        return pairs
    }

    @Test func textOnEveryAccentSurfaceReadsAtFourAndAHalfToOneOrMore() throws {
        for mode in ["light", "dark"] {
            let pairs = try Self.textOnAccent(mode)
            #expect(pairs.count == 30)
            for (place, ink, surface) in pairs {
                let ratio = RGBA.contrast(ink.over(surface), surface)
                #expect(ratio >= 4.5, "\(mode) \(place): \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// The opacity RowView gives a row whose reading is stale.
    static func staleDim() throws -> Double {
        let text = try AppSurfaceTests.source("RowView.swift")
        let match = try #require(text.firstMatch(of: /model\.dimmed \? ([0-9.]+) : 1/))
        return try #require(Double(match.output.1))
    }

    /// Each violet shape that marks a state or a control, with the surface it sits on.
    static func shapesOnSurfaces(_ mode: String) throws -> [(String, RGBA, RGBA)] {
        let tokens = try palette(mode)
        func t(_ name: String) throws -> RGBA { try token(tokens, name, mode) }
        let panel = try t("flatPanel")
        var pairs: [(String, RGBA, RGBA)] = []
        // The ring of each control on the accent; on dark surfaces the fill inside reads under 3:1.
        let surfaces = try [
            ("the window's list", t("winSide")), ("the window and its sheets", t("winBg")),
            ("the menu panel", panel),
        ]
        for (place, surface) in surfaces {
            pairs.append(("accent ring on \(place)", try t("accentRing"), surface))
        }
        // The bars along their gradient, on the panel, on a hovered row and on their track.
        let unders = try [
            ("panel", panel), ("hovered row", t("hover").over(panel)),
            ("track", t("track").over(panel)),
        ]
        for step in 0...10 {
            let bar = try t("barStart").toward(t("barEnd"), Double(step) / 10)
            for (place, under) in unders {
                pairs.append(("bar at \(step * 10)% on the \(place)", bar, under))
            }
        }
        pairs.append(("estimate dashes on the panel", try t("estimate"), panel))
        return pairs
    }

    @Test func everyVioletShapeThatMarksAStateOrAControlReadsAtThreeToOneOrMore() throws {
        for mode in ["light", "dark"] {
            let pairs = try Self.shapesOnSurfaces(mode)
            #expect(pairs.count == 37)
            for (place, shape, surface) in pairs {
                let ratio = RGBA.contrast(shape.over(surface), surface)
                #expect(ratio >= 3, "\(mode) \(place): \(String(format: "%.2f", ratio)):1")
            }
        }
    }
}

/// The views drawn on the accent, read from the app's sources.
extension ColorSchemeTests {
    /// Each view drawn on the accent, when it is, and whether it fills with the accent itself.
    static let onAccentViews: [(view: String, state: String, fills: Bool)] = [
        ("ActionRow", "hovering", true), ("AccountListRow", "selected", true),
        ("ChromeButton", "style == .primary", true), ("RadioDot", "on", true),
        ("SmallBadge", "selected", false),
    ]

    /// What a view may paint while it is on the accent.
    static let onAccentPaints: Set<String> = [
        "palette.accent", "palette.accentRing", "palette.onAccent", "palette.onAccentSoft",
        "palette.onAccentBadge", "Color.clear", ".clear", "nil",
    ]

    /// The SwiftUI color names a branch can give with a leading dot.
    static let colorNames: Set<String> = [
        "white", "black", "gray", "red", "orange", "yellow", "green", "mint", "teal", "cyan",
        "blue", "indigo", "purple", "pink", "brown", "clear", "primary", "secondary",
        "accentColor",
    ]

    static func folded(_ code: some StringProtocol) -> String {
        code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Each struct of the app's sources, by name, with its body.
    static func appStructs() throws -> [String: String] {
        var out: [String: String] = [:]
        for (_, text) in try AppSurfaceTests.appSources() {
            for match in text.matches(of: /struct (\w+)[^{\n]*\{/) {
                let name = String(match.output.1)
                let rest = String(text[match.range.lowerBound...])
                out[name] = AppSurfaceTests.block(after: "struct \(name)", in: rest)
            }
        }
        return out
    }

    /// The first branch of each `state ? a : b` and `state && more ? a : b` in `code`.
    static func firstBranches(of state: String, in code: String) -> [String] {
        let code = folded(code)
        var out: [String] = []
        var from = code.startIndex
        while let found = code.range(of: state, range: from..<code.endIndex) {
            from = found.upperBound
            if found.lowerBound > code.startIndex {
                let before = code[code.index(before: found.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" || before == "." { continue }
            }
            let tail = code[found.upperBound...]
            guard let mark = tail.range(of: " ? "),
                let colon = tail[mark.upperBound...].range(of: " : ")
            else { continue }
            let narrower = tail[..<mark.lowerBound]
            let plain = narrower.isEmpty
            let and =
                narrower.hasPrefix(" && ") && !narrower.contains(where: { "?:(),{}".contains($0) })
            if plain || and { out.append(String(tail[mark.upperBound..<colon.lowerBound])) }
        }
        return out
    }

    /// The text inside each `call(...)` in `code`, with whitespace folded.
    static func arguments(of call: String, in code: String) -> [String] {
        var out: [String] = []
        var rest = Substring(code)
        while let found = rest.range(of: call + "(") {
            let from = String(rest[found.lowerBound...])
            if let inside = parenthesized(after: call + "(", in: from) {
                out.append(folded(inside))
            }
            rest = rest[found.upperBound...]
        }
        return out
    }

    @Test func everyViewOnTheAccentPaintsOnlyOnAccentTokensThereAndRingsItsFill() throws {
        let structs = try Self.appStructs()
        // A view that starts to fill with the accent has to join the table.
        let filling = structs.filter { $0.value.contains(/palette\.accent(?![A-Za-z])/) }.keys
        #expect(Set(filling) == Set(Self.onAccentViews.filter { $0.fills }.map { $0.view }))
        for (view, state, fills) in Self.onAccentViews {
            let code = try #require(structs[view], "\(view)")
            // No inline white or black: each mark on the accent is a token the tests read.
            for inline in ["Color.white", "Color.black", "Color(white"] {
                #expect(!code.contains(inline), "\(view) draws \(inline)")
            }
            #expect(!code.contains(/[^A-Za-z0-9_]\.(white|black)(?![A-Za-z0-9_])/), "\(view)")
            let branches = Self.firstBranches(of: state, in: code)
            for branch in branches {
                let paint = branch.components(separatedBy: ".opacity(")[0]
                let named =
                    paint.hasPrefix(".") && Self.colorNames.contains(String(paint.dropFirst()))
                guard paint.hasPrefix("palette.") || paint.hasPrefix("Color") || named else {
                    continue
                }
                #expect(Self.onAccentPaints.contains(paint), "\(view): \(state) ? \(branch)")
            }
            // What it draws only in that state, such as a chosen radio's center.
            var rest = Substring(code)
            while let found = rest.range(of: "if \(state) {") {
                let only = AppSurfaceTests.block(
                    after: "if \(state)", in: String(rest[found.lowerBound...]))
                for match in (only ?? "").matches(of: /palette\.\w+|Color\.\w+/) {
                    let paint = String(match.output)
                    #expect(
                        Self.onAccentPaints.contains(paint), "\(view): if \(state) { \(paint) }")
                }
                rest = rest[found.upperBound...]
            }
            // Each text color the view sets turns to an on-accent token in that state.
            for call in [".foregroundStyle", ".foregroundColor"] {
                for style in Self.arguments(of: call, in: code) where style != "ink" {
                    let first = Self.firstBranches(of: state, in: style).first ?? ""
                    let onAccent = ["palette.onAccent", "palette.onAccentSoft"].contains(first)
                    #expect(
                        style.hasPrefix(state + " ? ") && onAccent, "\(view): \(call)(\(style))")
                }
            }
            if fills {
                #expect(branches.contains("palette.accent"), "\(view) \(branches)")
                #expect(branches.contains("palette.accentRing"), "\(view) draws no accent ring")
            }
        }
        // The primary button's ink, and the main badge on a selected account.
        let button = Self.folded(try #require(structs["ChromeButton"]))
        #expect(button.contains("case .primary: return palette.onAccent "), "\(button)")
        let row = try #require(structs["AccountListRow"])
        let badges = Self.arguments(of: "SmallBadge", in: row)
        #expect(!badges.isEmpty && badges.allSatisfy { $0.contains("selected: selected") })
    }
}

/// A PNG's pixels as 8-bit sRGB, top row first.
struct PNGPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    init(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw Unreadable(description: "cannot read \(url.lastPathComponent)") }
        let (w, h) = (image.width, image.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw Unreadable(description: "cannot draw \(url.lastPathComponent)") }
        width = w
        height = h
        bytes = data
    }

    func color(_ x: Int, _ y: Int) -> RGBA {
        color(at: (y * width + x) * 4)
    }

    private func color(at i: Int) -> RGBA {
        RGBA(
            r: Double(bytes[i]) / 255, g: Double(bytes[i + 1]) / 255,
            b: Double(bytes[i + 2]) / 255, a: Double(bytes[i + 3]) / 255)
    }

    /// The `count` most common opaque colors, counting every seventh pixel.
    func commonColors(_ count: Int) -> [RGBA] {
        var tally: [UInt32: Int] = [:]
        for i in stride(from: 0, to: bytes.count, by: 28) where bytes[i + 3] == 255 {
            let key = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
            tally[key, default: 0] += 1
        }
        let ranked = tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        return ranked.prefix(count).map { RGBA(hex: $0.key) }
    }

    /// Each drawn pixel with chroma of at least `floor`; grays are skipped in whole numbers.
    func colors(withChromaOf floor: Double) -> [RGBA] {
        let least = Int((floor * 255).rounded(.up))
        var out: [RGBA] = []
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 0 {
            let (r, g, b) = (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
            if max(r, g, b) - min(r, g, b) >= least { out.append(color(at: i)) }
        }
        return out
    }
}

/// The drawn views, read back from the app's own render.
extension ColorSchemeTests {
    /// The next pick's tint: the rows it spans, and its hues at the left and the right.
    struct Tint: CustomStringConvertible {
        let top, bottom: Int
        let left, right: Double
        var description: String { "rows \(top) to \(bottom), hue \(left) to \(right)" }

        /// Violet to blue with both ends capped, since faint orange on the bluish panel reads 345.
        var runsVioletToBlue: Bool {
            (245...290).contains(left) && (200...235).contains(right) && left - right >= 15
        }
    }

    /// A run of fill along one row, with the hues one pixel in from its ends.
    struct Run: CustomStringConvertible {
        let row: Int
        let start, end: Double
        var description: String { "row \(row), hue \(start) to \(end)" }
    }

    /// A faint violet or blue, as the next pick's tint draws over the panel.
    static func isTint(_ color: RGBA) -> Bool {
        color.chroma >= 0.02 && color.hue >= 200 && color.hue <= 300
    }

    /// A strong violet or blue, as a bar's fill or the tile draws.
    static func isFill(_ color: RGBA) -> Bool {
        color.chroma >= 0.25 && color.hue >= 195 && color.hue <= 300
    }

    /// The first tinted block on `panel`, its edges where the panel color starts again.
    static func nextPick(_ picture: PNGPixels, panel: RGBA) -> Tint? {
        let center = picture.width / 2
        func onPanel(_ x: Int, _ y: Int) -> Bool { picture.color(x, y).isNear(panel) }
        guard let panelTop = (0..<picture.height).first(where: { onPanel(center, $0) }),
            let top = (panelTop..<picture.height).first(where: {
                !onPanel(center, $0) && isTint(picture.color(center, $0))
            })
        else { return nil }
        let row = top + 4
        var (left, right) = (center, center)
        while left > 0 && !onPanel(left - 1, row) { left -= 1 }
        while right < picture.width - 1 && !onPanel(right + 1, row) { right += 1 }
        var bottom = row
        while bottom < picture.height - 1 && !onPanel(left + 6, bottom + 1) { bottom += 1 }
        return Tint(
            top: top, bottom: bottom, left: picture.color(left + 4, row).hue,
            right: picture.color(right - 4, row).hue)
    }

    /// Each run of fill at least 16 pixels long on the rows from `from` down.
    static func fillRuns(_ picture: PNGPixels, from: Int) -> [Run] {
        var runs: [Run] = []
        for y in from..<picture.height {
            var x = 0
            while x < picture.width {
                guard isFill(picture.color(x, y)) else {
                    x += 1
                    continue
                }
                let first = x
                while x + 1 < picture.width && isFill(picture.color(x + 1, y)) { x += 1 }
                if x - first + 1 >= 16 {
                    let (start, end) = (picture.color(first + 1, y), picture.color(x - 1, y))
                    runs.append(Run(row: y, start: start.hue, end: end.hue))
                }
                x += 1
            }
        }
        return runs
    }

    /// The mean hue of the fill on the first three and the last three rows above `row`.
    static func tileHues(_ picture: PNGPixels, above row: Int) -> (upper: Double, lower: Double)? {
        var hues: [(Int, Double)] = []
        for y in 0..<row {
            for x in 0..<picture.width where isFill(picture.color(x, y)) {
                hues.append((y, picture.color(x, y).hue))
            }
        }
        let rows = Array(Set(hues.map(\.0))).sorted()
        guard rows.count > 20 else { return nil }
        func mean(_ wanted: ArraySlice<Int>) -> Double {
            let picked = hues.filter { wanted.contains($0.0) }.map(\.1)
            return picked.reduce(0, +) / Double(picked.count)
        }
        return (mean(rows.prefix(3)), mean(rows.suffix(3)))
    }

    @Test func theBarsTheNextPickTheEmptyCardAndTheIconTileDrawTheGradientInBothModes() throws {
        try AppSurfaceTests.withRenderRoot { root in
            let repo = root.appendingPathComponent("repo")
            let home = root.appendingPathComponent("home")
            for flag in [["--render", "build/r"], ["--iconset", "build/i"]] {
                let (status, _) = try AppSurfaceTests.renderFlag(flag, cwd: repo, home: home)
                try #require(status == 0, "\(flag)")
            }
            for mode in ["light", "dark"] {
                let picture = try PNGPixels(
                    repo.appendingPathComponent("build/r/menu-\(mode).png"))
                let panel = try Self.token(Self.palette(mode), "flatPanel", mode)
                let next = try #require(
                    Self.nextPick(picture, panel: panel), "\(mode): no next pick tint")
                #expect(next.bottom - next.top > 100, "\(mode) next pick \(next)")
                #expect(next.runsVioletToBlue, "\(mode) next pick \(next)")
                // The card an empty menu shows in the next pick's place runs the same way.
                let empty = try PNGPixels(
                    repo.appendingPathComponent("build/r/empty-first-run-\(mode).png"))
                let card = try #require(
                    Self.nextPick(empty, panel: panel), "\(mode): no empty card tint")
                #expect(card.bottom - card.top > 100, "\(mode) empty card \(card)")
                #expect(card.runsVioletToBlue, "\(mode) empty card \(card)")
                // Each bar of normal use runs from violet at its start toward blue at its end.
                let runs = Self.fillRuns(picture, from: next.bottom + 1)
                #expect(runs.count >= 48, "\(mode): \(runs.count) bar rows")
                for run in runs {
                    #expect(run.start >= 240 && run.start - run.end >= 15, "\(mode) bar \(run)")
                }
                #expect((runs.map(\.end).min() ?? 360) <= 225, "\(mode): no bar reaches blue")
                // The header's tile is violet at its top and blue at its bottom.
                let tile = try #require(Self.tileHues(picture, above: next.top), "\(mode) tile")
                #expect(tile.upper >= 250 && tile.lower <= 230, "\(mode) header tile \(tile)")
            }
            let icon = try PNGPixels(repo.appendingPathComponent("build/i/icon_512x512.png"))
            // The tile's middle column, just inside its top and bottom edges.
            let (top, bottom) = (icon.color(256, 60), icon.color(256, 452))
            #expect(top.a == 1 && bottom.a == 1 && icon.color(5, 5).a == 0)
            #expect(top.hue >= 250 && bottom.hue <= 230, "icon \(top) to \(bottom)")
        }
    }

    /// The longest run of `color` along one row: its row, first pixel and length.
    static func longestRun(_ picture: PNGPixels, of color: RGBA) -> (y: Int, x: Int, length: Int)? {
        var best: (y: Int, x: Int, length: Int)?
        for y in 0..<picture.height {
            var x = 0
            while x < picture.width {
                guard picture.color(x, y).isNear(color) else {
                    x += 1
                    continue
                }
                let first = x
                while x + 1 < picture.width && picture.color(x + 1, y).isNear(color) { x += 1 }
                if x - first + 1 > (best?.length ?? 0) { best = (y, first, x - first + 1) }
                x += 1
            }
        }
        return best
    }

    @Test func aStaleRowDimsAllButItsMainBadgeWhoseTextReadsAtFourAndAHalfToOneOrMore() throws {
        let dim = try Self.staleDim()
        try AppSurfaceTests.withRenderRoot { root in
            let repo = root.appendingPathComponent("repo")
            let (status, _) = try AppSurfaceTests.renderFlag(
                ["--render", "build/r"], cwd: repo, home: root.appendingPathComponent("home"))
            try #require(status == 0)
            for mode in ["light", "dark"] {
                // This menu's main account has a reading hours old.
                let picture = try PNGPixels(
                    repo.appendingPathComponent("build/r/menu-states-\(mode).png"))
                let tokens = try Self.palette(mode)
                let panel = try Self.token(tokens, "flatPanel", mode)
                // The badge is found by its tint at full strength: a dimmed one does not match.
                let tint = try Self.token(tokens, "badgeMainBg", mode).over(panel)
                let run = try #require(Self.longestRun(picture, of: tint), "\(mode): no badge")
                try #require(run.length >= 40, "\(mode): no main badge at full strength, \(run)")
                func inBadge(_ y: Int) -> Bool { picture.color(run.x + 6, y).isNear(tint) }
                var (top, bottom) = (run.y, run.y)
                while top > 0 && inBadge(top - 1) { top -= 1 }
                while bottom < picture.height - 1 && inBadge(bottom + 1) { bottom += 1 }
                var (ink, label) = (1.0, panel)
                for y in top...bottom {
                    for x in run.x..<(run.x + run.length) {
                        ink = max(ink, RGBA.contrast(picture.color(x, y), tint))
                    }
                    for x in 0..<run.x
                    where RGBA.contrast(picture.color(x, y), panel) > RGBA.contrast(label, panel) {
                        label = picture.color(x, y)
                    }
                }
                #expect(ink >= 4.5, "\(mode) stale main badge: \(String(format: "%.2f", ink)):1")
                // The label beside it is dimmed, so this is the stale row.
                let text1 = try Self.token(tokens, "text1", mode)
                let dimmed = RGBA(r: text1.r, g: text1.g, b: text1.b, a: dim).over(panel)
                #expect(dim < 1 && label.isNear(dimmed), "\(mode) label \(label), not \(dimmed)")
            }
        }
    }

    /// The amber warning and the macOS minimize light sit at 39 to 41 degrees, so this stops at 35.
    @Test func theReadmePicturesHoldNoOrangeAndNoWarmSurface() throws {
        let media = Support.root.appendingPathComponent("docs/media")
        var checked = 0
        for scene in ["hero", "menu", "manage-tokens", "manage-folders"] {
            for mode in ["light", "dark"] {
                let picture = try PNGPixels(media.appendingPathComponent("\(scene)-\(mode).png"))
                let colored = picture.colors(withChromaOf: 0.15)
                #expect(colored.count > 1000, "\(scene)-\(mode)")
                let orange = colored.filter { $0.hue >= 10 && $0.hue < 35 }.count
                #expect(orange == 0, "\(scene)-\(mode): \(orange) orange pixels")
                // The two largest surfaces, the backdrop and the menu or window, carry no warm cast.
                for color in picture.commonColors(2) {
                    #expect(Self.isCoolNeutral(color), "\(scene)-\(mode): \(color) is warm")
                }
                checked += 1
            }
        }
        #expect(checked == 8)
    }
}
