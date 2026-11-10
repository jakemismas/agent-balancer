import Foundation

/// Makes an externally derived string safe to print on a terminal.
public enum Display {
    public static let defaultLimit = 120

    /// Replaces every control, format, line and paragraph separator scalar with a visible
    /// `\u{XX}` escape, then caps the length.
    public static func safe(_ text: String, limit: Int = defaultLimit) -> String {
        var out = ""
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= limit {
                out += "..."
                break
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate,
                .privateUse, .unassigned:
                out += "\\u{" + String(scalar.value, radix: 16) + "}"
            default:
                out.unicodeScalars.append(scalar)
            }
            count += 1
        }
        return out
    }
}
