import Foundation

/// Redacts secrets and personal text. It works on whole captured buffers, never per read, so a
/// value split across two reads is still caught.
public enum Scrubber {
    public static let redacted = "[redacted]"

    private static let tokenPrefix = try! NSRegularExpression(pattern: "sk-ant-[A-Za-z0-9_-]*")
    private static let uuid = try! NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    private static let userPath = try! NSRegularExpression(pattern: "/Users/[^/\\s\"'\\\\]+")

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
        var out = redactEmails(text)
        out = replace(uuid, in: out, with: "[id]")
        out = replace(userPath, in: out, with: "/Users/[user]")
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

    /// Replaces `local@label(.label)+` with `[email]` in one pass that anchors on each `@` and
    /// walks outward, so a long run of address characters costs linear time.
    private static func redactEmails(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.contains(0x40) else { return text }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        let marker = Array("[email]".utf8)
        var copied = 0
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x40 else {
                i += 1
                continue
            }
            var start = i
            while start > copied && isLocalByte(bytes[start - 1]) { start -= 1 }
            var j = i + 1
            var labels = 0
            while true {
                let labelStart = j
                while j < bytes.count && isLabelByte(bytes[j]) { j += 1 }
                if j == labelStart { break }
                labels += 1
                if j + 1 < bytes.count && bytes[j] == 0x2E && isLabelByte(bytes[j + 1]) {
                    j += 1
                } else {
                    break
                }
            }
            if start < i && labels >= 2 {
                out += bytes[copied..<start]
                out += marker
                copied = j
                i = j
            } else {
                i += 1
            }
        }
        out += bytes[copied...]
        return String(decoding: out, as: UTF8.self)
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
