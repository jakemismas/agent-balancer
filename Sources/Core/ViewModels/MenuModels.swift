import Foundation

public enum MeterTone: Equatable, Sendable {
    case normal, warn, crit
}

public struct MeterModel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A solid fill: fraction of the cap used, 0 to 1.
        case solid(Double)
        /// Before a first Fable reading: the span that may be used, and the part that is free.
        case estimate(free: Double, possible: Double)
    }

    public var name: String
    public var kind: Kind
    public var tone: MeterTone
    public var valueText: String
    public var accessibilityLabel: String
    public var accessibilityValue: String
}

public struct RowNote: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case info, warning }
    public var text: String
    public var style: Style
}

public struct StepsModel: Equatable, Sendable {
    public var steps: [String]
    public var command: String?
}

public struct ErrorModel: Equatable, Sendable {
    public var title: String
    public var text: String
    public var steps: StepsModel
    /// True when the Manage accounts window can fix it: its fix action opens the window on the account.
    public var manageable: Bool = false
}

public struct MetersModel: Equatable, Sendable {
    public var all: MeterModel
    public var fable: MeterModel?
    public var resetText: String?
}

public enum RowBody: Equatable, Sendable {
    case meters(MetersModel)
    case error(ErrorModel)
    case note(String)
}

public struct RowModel: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public var label: String
    public var email: String?
    public var roleBadge: String
    public var isMain: Bool
    public var endBadge: String?
    public var inUseText: String?
    public var body: RowBody
    public var notes: [RowNote]
    /// True when the reading is older than twice the refresh interval.
    public var dimmed: Bool
}

public struct NextModel: Equatable, Sendable {
    public var allLabel: String
    public var allReason: String
    public var fableLabel: String
    public var fableReason: String
}

public struct BannerModel: Equatable, Sendable {
    public var text: String
    public var command: String?
}

public struct AccountsScreen: Equatable, Sendable {
    public var updatedText: String?
    public var next: NextModel?
    public var banner: BannerModel?
    public var rows: [RowModel]
}

public struct CardModel: Equatable, Sendable {
    public var title: String
    public var text: String
    public var command: String?
    public var lines: [String]
}

public enum MenuScreen: Equatable, Sendable {
    case accounts(AccountsScreen)
    case card(CardModel)
}

public enum RefreshState: Equatable, Sendable {
    case idle
    case running
    case failed(String)
}

/// Every tip text the menu shows. A test lists them and sees none longer than two sentences.
public enum MenuTips {
    public static let fableMeter =
        "Weekly use of the Fable model, read about once a day. Before the first reading, the dashed span is the most that may be used."
    public static let all = [fableMeter]
}

public enum MenuFormat {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = LocalTime.zone
        f.dateFormat = format
        return f
    }

    /// "Wed 9:00 AM"
    public static func when(_ date: Date) -> String { formatter("EEE h:mm a").string(from: date) }

    /// "2026-11-16" becomes "Nov 16". Anything else, which can come from a rewritten status file,
    /// goes through the display-safe pass.
    public static func day(_ isoDate: String) -> String {
        dayIfDate(isoDate) ?? Display.safe(isoDate, limit: 32)
    }

    /// "Nov 16" for a real day written `YYYY-MM-DD`, or nil for anything else.
    static func dayIfDate(_ isoDate: String) -> String? {
        guard let parts = dateParts(isoDate) else { return nil }
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        return "\(months[parts.month - 1]) \(parts.day)"
    }

    static func dateParts(_ isoDate: String) -> (year: Int, month: Int, day: Int)? {
        guard ConfigValidator.isValidDate(isoDate) else { return nil }
        let parts = isoDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// "just now", "2 min ago", "2 h ago", "3 d ago"
    public static func ago(seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded())) min ago" }
        if s < 48 * 3600 { return "\(Int((Double(s) / 3600).rounded())) h ago" }
        return "\(Int((Double(s) / 86400).rounded())) d ago"
    }

    /// 41.0 becomes "41%", 12.5 stays "12.5%".
    public static func percent(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if let whole = Int(exactly: rounded) { return "\(whole)%" }
        return "\(rounded)%"
    }
}

public struct MenuInputs: Sendable {
    public var configExists: Bool
    public var cliFound: Bool
    public var cliTried: [String]
    public var status: StatusLoad
    public var now: Date
    public var backgroundMinutes: Int

    public init(
        configExists: Bool, cliFound: Bool, cliTried: [String], status: StatusLoad, now: Date,
        backgroundMinutes: Int
    ) {
        self.configExists = configExists
        self.cliFound = cliFound
        self.cliTried = cliTried
        self.status = status
        self.now = now
        self.backgroundMinutes = backgroundMinutes
    }
}

public enum MenuBuilder {
    public static let initCommand = "agent-balancer init"
    static let hiddenWarnings: Set<String> = ["key_in_settings", "launch_file_missing"]
    /// The error codes the Manage accounts window fixes.
    static let manageableCodes: Set<String> = ["login_rejected", "token_missing", "not_linked"]

    /// Chooses what the window shows. It is never empty: every path ends in rows or a card.
    public static func screen(_ inputs: MenuInputs) -> MenuScreen {
        if case .newerSchema = inputs.status {
            return .card(
                CardModel(
                    title: "Update agent-balancer",
                    text:
                        "The status file is newer than this app reads. Update agent-balancer and this app.",
                    command: nil, lines: []))
        }
        if case .loaded(let snapshot) = inputs.status, !snapshot.accounts.isEmpty {
            return .accounts(accounts(snapshot, inputs))
        }
        if !inputs.cliFound {
            return .card(
                CardModel(
                    title: "agent-balancer not found",
                    text: "The app looks only in these places.", command: nil,
                    lines: inputs.cliTried))
        }
        if !inputs.configExists {
            return .card(
                CardModel(
                    title: "Set up agent-balancer",
                    text: "No config yet. Run this in Terminal.", command: initCommand, lines: []))
        }
        if case .unreadable(let text) = inputs.status {
            return .card(
                CardModel(title: "Status unavailable", text: text, command: nil, lines: []))
        }
        return .card(
            CardModel(
                title: "Reading accounts", text: "The first reading takes a minute.", command: nil,
                lines: []))
    }

    /// Seconds after which a row's reading is stale: two refresh intervals, worked out in `Double`
    /// so no interval can overflow.
    static func staleAfterSeconds(backgroundMinutes: Int) -> Double {
        Double(backgroundMinutes) * 120
    }

    static func accounts(_ snapshot: StatusSnapshot, _ inputs: MenuInputs) -> AccountsScreen {
        let staleAfter = staleAfterSeconds(backgroundMinutes: inputs.backgroundMinutes)
        let rows = snapshot.accounts.map { row($0, staleAfter: staleAfter) }
        var banner: BannerModel?
        if let b = snapshot.banner {
            banner = BannerModel(text: plain(b.text), command: command(in: b.text))
        } else if let a = snapshot.accounts.first(where: { $0.error?.code == "settings_changed" }),
            let e = a.error
        {
            banner = BannerModel(text: plain(e.text), command: command(in: e.text))
        }
        var next: NextModel?
        if let n = snapshot.next {
            next = NextModel(
                allLabel: shownLabel(n.all.label ?? "none"),
                allReason: Display.safe(n.all.reason, limit: 240),
                fableLabel: shownLabel(n.fable.label ?? "none"),
                fableReason: Display.safe(n.fable.reason, limit: 240))
        }
        var updated: String?
        if let at = snapshot.generatedAt {
            let age = Int(inputs.now.timeIntervalSince(at))
            updated = "Updated " + MenuFormat.ago(seconds: age)
        }
        return AccountsScreen(updatedText: updated, next: next, banner: banner, rows: rows)
    }

    /// Texts carry commands in backticks; the screen shows them without the marks, through the
    /// display-safe pass because a status file can be rewritten.
    static func plain(_ text: String) -> String {
        Display.safe(text.replacingOccurrences(of: "`", with: ""), limit: 400)
    }

    /// An account label from the status file, as the screen shows it.
    static func shownLabel(_ label: String) -> String {
        Display.safe(label, limit: 64)
    }

    /// The command inside the first pair of backticks, when it starts with the tool's name.
    static func command(in text: String) -> String? {
        let pieces = text.split(separator: "`", omittingEmptySubsequences: false)
        guard pieces.count >= 3 else { return nil }
        let candidate = String(pieces[1])
        return allowedCommand(candidate)
    }

    private static let fixedCommands: Set<String> = [
        "agent-balancer init", "agent-balancer doctor", "agent-balancer refresh",
        "agent-balancer link --accept-source-change",
    ]
    private static let labelVerbs: Set<String> = ["login", "link"]

    /// Accepts only a fixed command or a login or link verb with one safe label.
    static func allowedCommand(_ candidate: String) -> String? {
        if fixedCommands.contains(candidate) { return candidate }
        let parts = candidate.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "agent-balancer", labelVerbs.contains(String(parts[1])),
            safeLabel(String(parts[2]))
        else { return nil }
        return candidate
    }

    static func safeLabel(_ label: String) -> Bool {
        guard let first = label.unicodeScalars.first, label.count <= 64 else { return false }
        let alnum = CharacterSet.alphanumerics
        guard alnum.contains(first), first.isASCII else { return false }
        return label.unicodeScalars.allSatisfy {
            $0.isASCII && (alnum.contains($0) || $0 == "-" || $0 == "_" || $0 == ".")
        }
    }

    static func title(for code: String) -> String {
        let words = Display.safe(code, limit: 64).replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Steps that name an action only the menu has, so the Manage accounts window leaves them out.
    static let menuOnlySteps: Set<String> = ["Choose Refresh now."]

    /// The steps for a code. A login account is the default folder's own sign-in: it has no
    /// folder of its own to relabel, and `agent-balancer login` refuses it.
    static func steps(code: String, label: String, kind: String? = nil) -> StepsModel {
        let ok = safeLabel(label)
        switch (code, kind == Kind.login) {
        case ("login_rejected", true):
            return StepsModel(
                steps: ["Open Terminal.", "Run claude and sign in again.", "Choose Refresh now."],
                command: nil)
        case ("wrong_account", true):
            return StepsModel(
                steps: [Messages.signExpectedBackInLogin, "Choose Refresh now."], command: nil)
        default: break
        }
        switch code {
        case "login_rejected", "token_missing":
            return StepsModel(
                steps: [
                    "Open Terminal.", "Run the command below and sign in.", "Choose Refresh now.",
                ],
                command: ok ? "agent-balancer login \(label)" : nil)
        case "not_linked":
            return StepsModel(
                steps: [
                    "Open Terminal.", "Run the command below and type the label when asked.",
                    "Choose Refresh now.",
                ], command: ok ? "agent-balancer link \(label)" : nil)
        case "wrong_account":
            return StepsModel(
                steps: [Messages.signExpectedBackIn, "Choose Refresh now."], command: nil)
        default:
            return StepsModel(
                steps: ["Fix what the message says.", "Choose Refresh now."], command: nil)
        }
    }

    static func row(_ a: AccountSnapshot, staleAfter: Double) -> RowModel {
        let isMain = a.role == "main"
        var endBadge: String?
        if let ends = a.endsAt, !ends.isEmpty {
            endBadge = "ends " + MenuFormat.day(ends)
        } else if a.endingSoon {
            endBadge = "ending soon"
        }
        var inUse: String?
        if let n = a.inUse?.count, n > 0 { inUse = "\(n) in use" }

        var notes: [RowNote] = []
        let ageStale = Double(a.readingsAge ?? 0) > staleAfter
        var dimmed = false
        let body: RowBody
        if a.state == "error", let e = a.error, e.code != "settings_changed" {
            // The window has nothing to change for a login account.
            body = .error(
                ErrorModel(
                    title: title(for: e.code), text: plain(e.text),
                    steps: steps(code: e.code, label: a.label, kind: a.kind),
                    manageable: manageableCodes.contains(e.code) && a.kind != Kind.login))
        } else if a.state == "ended" {
            body = .note(plain(a.error?.text ?? "Account ended."))
        } else if let weekly = a.weekly, let used = weekly.usedPercent {
            body = .meters(meters(a, weekly: weekly, used: used))
            if a.state == "limited" {
                let until = a.limited?.until.map { " until " + MenuFormat.when($0) } ?? ""
                notes.append(RowNote(text: "Limited\(until).", style: .warning))
            }
            var hasStaleWarning = false
            for w in a.warnings where !hiddenWarnings.contains(w.code) {
                if w.code == "stale" { hasStaleWarning = true }
                notes.append(RowNote(text: plain(w.text), style: .warning))
            }
            if ageStale {
                dimmed = true
                if !hasStaleWarning, let age = a.readingsAge {
                    notes.append(
                        RowNote(text: "Last read \(MenuFormat.ago(seconds: age)).", style: .warning)
                    )
                }
            }
        } else if a.error?.code == "settings_changed" {
            body = .note("Paused until the settings fix above.")
        } else {
            body = .note("Reading accounts")
        }
        return RowModel(
            label: shownLabel(a.label), email: a.email.map { Display.safe($0) },
            roleBadge: isMain ? "main" : "pool", isMain: isMain, endBadge: endBadge,
            inUseText: inUse, body: body, notes: notes, dimmed: dimmed)
    }

    static func tone(_ used: Double) -> MeterTone {
        if used >= 95 { return .crit }
        if used >= 80 { return .warn }
        return .normal
    }

    static func meters(_ a: AccountSnapshot, weekly: SnapshotWindow, used: Double) -> MetersModel {
        let label = shownLabel(a.label)
        let reset = weekly.resetsAt
        let resetWords = reset.map { ", resets " + MenuFormat.when($0) } ?? ""
        let allModels = MeterModel(
            name: "All models", kind: .solid(clamp(used) / 100), tone: tone(used),
            valueText: MenuFormat.percent(used) + " used",
            accessibilityLabel: "\(label), all models" + resetWords,
            accessibilityValue: MenuFormat.percent(used) + " used")
        var fable: MeterModel?
        if let f = a.fable {
            let fableReset = f.resetsAt ?? reset
            let fableResetWords = fableReset.map { ", resets " + MenuFormat.when($0) } ?? ""
            if let fu = f.usedPercent {
                fable = MeterModel(
                    name: "Fable", kind: .solid(clamp(fu) / 100), tone: .normal,
                    valueText: MenuFormat.percent(fu) + " used",
                    accessibilityLabel: "\(label), Fable" + fableResetWords,
                    accessibilityValue: MenuFormat.percent(fu) + " of the Fable cap used")
            } else if f.source == "estimate" || f.guaranteedLeftPercentOfCap != nil {
                let free = clamp(f.guaranteedLeftPercentOfCap ?? 0)
                let possible = 100 - free
                let text = "up to " + MenuFormat.percent(possible) + " used (est.)"
                fable = MeterModel(
                    name: "Fable", kind: .estimate(free: free / 100, possible: possible / 100),
                    tone: .normal, valueText: text,
                    accessibilityLabel: "\(label), Fable, estimate" + fableResetWords,
                    accessibilityValue: text + " of the Fable cap")
            }
        }
        return MetersModel(
            all: allModels, fable: fable, resetText: reset.map { "Resets " + MenuFormat.when($0) })
    }

    static func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
}
