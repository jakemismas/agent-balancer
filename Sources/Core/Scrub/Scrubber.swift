import Foundation

/// Redacts secrets and personal text. It works on whole captured buffers, never per read, so a
/// value split across two reads is still caught.
public enum Scrubber {
    public static let redacted = "[redacted]"

    private static let tokenPrefix = try! NSRegularExpression(pattern: "sk-ant-[A-Za-z0-9_-]*")
    private static let uuid = try! NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    static let userPath = homePathRule(ownName: Env.userDatabaseHome().flatMap(homeName(in:)))

    /// `/Users/<name>` up to the first slash, whitespace, quote or backslash. For the user's own
    /// home folder the whole name goes first, so a space in it does not cut the redaction short.
    static func homePathRule(ownName: String?) -> NSRegularExpression {
        let rest = "[^/\\s\"'\\\\]"
        let own = ownName.map { NSRegularExpression.escapedPattern(for: $0) + rest + "*|" } ?? ""
        let generic = try! NSRegularExpression(pattern: "/Users/" + rest + "+")
        return (try? NSRegularExpression(pattern: "/Users/(?:" + own + rest + "+)")) ?? generic
    }

    /// The folder name of a home directly under `/Users`, the only home root the pass redacts.
    static func homeName(in path: String) -> String? {
        let parts = path.split(separator: "/")
        guard path.hasPrefix("/Users/"), parts.count == 2 else { return nil }
        return String(parts[1])
    }

    /// Token pass: any `sk-ant-` string, and any run of 32 or more `[A-Za-z0-9_-]` characters with
    /// Shannon entropy above 4.0 bits per character. Runs on every captured buffer before parsing.
    public static func tokenPass(_ text: String) -> String {
        let first = replace(tokenPrefix, in: text, with: redacted)
        return redactEntropyRuns(first)
    }

    public static func tokenPass(_ data: Data) -> String {
        tokenPass(String(decoding: data, as: UTF8.self))
    }

    /// Second pass: email addresses, UUIDs and `/Users/<name>`. For stderr, error texts and log
    /// lines only, never for the JSON fields the readers map.
    public static func personalPass(_ text: String) -> String {
        personalPass(text, homePaths: userPath)
    }

    /// The second pass with `homePaths` as its home path rule, so a test can name a home folder.
    static func personalPass(_ text: String, homePaths: NSRegularExpression) -> String {
        var out = redactEmails(text)
        out = replace(uuid, in: out, with: "[id]")
        out = replace(homePaths, in: out, with: "/Users/[user]")
        return out
    }

    /// Both passes, for anything a person sees or a log keeps.
    public static func scrubText(_ text: String) -> String {
        personalPass(tokenPass(text))
    }

    private static func replace(
        _ regex: NSRegularExpression, in text: String, with template: String
    )
        -> String
    {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    private static func isLocalByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == 0x2E || b == 0x5F || b == 0x25 || b == 0x2B || b == 0x2D
    }

    private static func isLabelByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == 0x2D
    }

    /// A letter, mark or digit outside ASCII, which an address may hold in its local part or host.
    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber,
            .otherNumber:
            return true
        default:
            return false
        }
    }

    // Every label character is also a local character, which keeps the address walk linear.
    private static func isLocal(_ s: Unicode.Scalar) -> Bool {
        s.isASCII ? isLocalByte(UInt8(s.value)) : isWordScalar(s)
    }

    private static func isLabel(_ s: Unicode.Scalar) -> Bool {
        s.isASCII ? isLabelByte(UInt8(s.value)) : isWordScalar(s)
    }

    /// Replaces `local@label(.label)*` with `[email]` in one pass that anchors on each `@` and
    /// walks outward, and builds the String once at the end, so the walk costs linear time however
    /// many addresses or address characters the text holds. A bare host counts, so `pat@localhost`
    /// and a `name@tag` text such as `react@19` both read as addresses, and a local part or label
    /// may hold letters and digits of any script.
    private static func redactEmails(_ text: String) -> String {
        guard text.utf8.contains(0x40) else { return text }
        let scalars = Array(text.unicodeScalars)
        let marker = Array("[email]".unicodeScalars)
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(scalars.count)
        var copied = 0
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "@" else {
                i += 1
                continue
            }
            var start = i
            while start > copied && isLocal(scalars[start - 1]) { start -= 1 }
            var j = i + 1
            while true {
                let labelStart = j
                while j < scalars.count && isLabel(scalars[j]) { j += 1 }
                if j == labelStart { break }
                // A dot joins the next label, and so does another `@`, so `a@b@c.example.com`
                // goes whole rather than leaving a host behind.
                if j + 1 < scalars.count && (scalars[j] == "." || scalars[j] == "@")
                    && isLabel(scalars[j + 1])
                {
                    j += 1
                } else {
                    break
                }
            }
            if start < i && j > i + 1 {
                out += scalars[copied..<start]
                out += marker
                copied = j
                i = j
            } else {
                i += 1
            }
        }
        out += scalars[copied...]
        return String(String.UnicodeScalarView(out))
    }

    private static func isRunByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == 0x5F
            || b == 0x2D
    }

    static func entropy(_ bytes: ArraySlice<UInt8>) -> Double {
        var counts = [Int](repeating: 0, count: 256)
        for b in bytes { counts[Int(b)] += 1 }
        let n = Double(bytes.count)
        var h = 0.0
        for c in counts where c > 0 {
            let p = Double(c) / n
            h -= p * log2(p)
        }
        return h
    }

    private static func redactEntropyRuns(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        let marker = Array(redacted.utf8)
        while i < bytes.count {
            guard isRunByte(bytes[i]) else {
                out.append(bytes[i])
                i += 1
                continue
            }
            var j = i
            while j < bytes.count && isRunByte(bytes[j]) { j += 1 }
            if j - i >= 32 && entropy(bytes[i..<j]) > 4.0 {
                out += marker
            } else {
                out += bytes[i..<j]
            }
            i = j
        }
        return String(decoding: out, as: UTF8.self)
    }
}
