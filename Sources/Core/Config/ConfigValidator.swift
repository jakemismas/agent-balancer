import Foundation

public enum ConfigValidator {
    public static func isValidLabel(_ label: String) -> Bool {
        label.range(of: #"\A[a-z0-9][a-z0-9-]{0,31}\z"#, options: .regularExpression) != nil
    }

    /// An address that is safe as one argument: no leading hyphen, space, quote or control
    /// character. `login --browser` passes only such an email to claude.
    public static func isPlainEmail(_ text: String) -> Bool {
        let pattern = #"\A[A-Za-z0-9._%+][A-Za-z0-9._%+-]*@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\z"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// A real calendar day written `YYYY-MM-DD`. `2026-13-45` and `2026-02-30` are refused.
    public static func isValidDate(_ text: String) -> Bool {
        guard text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil
        else { return false }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts3 = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let day = calendar.date(from: parts3) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: day)
        return back.year == parts[0] && back.month == parts[1] && back.day == parts[2]
    }

    /// A real day that is `now`'s local day or later. A new `ends` value must pass this.
    public static func isTodayOrLater(_ text: String, now: Date = Date()) -> Bool {
        guard isValidDate(text) else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return text >= formatter.string(from: now)
    }

    /// An ISO 8601 time such as `2026-11-11T17:03:00Z`.
    public static func isValidTimestamp(_ text: String) -> Bool {
        ISO8601DateFormatter().date(from: text) != nil
    }

    /// Throws on the first problem found, with a message that names the field and never a value
    /// that could be personal.
    public static func validate(_ config: Config, context: ToolContext? = nil) throws {
        guard config.schemaVersion == Config.currentSchema else {
            throw ToolError(
                "Config schemaVersion \(config.schemaVersion) is not supported. This version reads version \(Config.currentSchema)."
            )
        }
        let minutes = 1...ConfigLimits.spanMinutes
        let seconds = 1...ConfigLimits.spanSeconds
        try require("refresh.backgroundMinutes", config.refresh.backgroundMinutes, minutes)
        try require("probe.timeoutSeconds", config.probe.timeoutSeconds, seconds)
        let fable = config.fable
        try require("fable.capPercentOfWeekly", fable.capPercentOfWeekly, 1...100)
        if !(fable.probeBudgetUsd > 0) || fable.probeBudgetUsd > 100 {
            throw ToolError("fable.probeBudgetUsd must be more than 0 and at most 100.")
        }
        try require("fable.probeTimeoutSeconds", fable.probeTimeoutSeconds, seconds)
        try require("fable.minRoomPercentOfCap", fable.minRoomPercentOfCap, 0...100)
        try require(
            "fable.recheckAfterWeeklyRisePercent", fable.recheckAfterWeeklyRisePercent, 0...100)
        let picker = config.picker
        try require("picker.maxReadingAgeMinutes", picker.maxReadingAgeMinutes, minutes)
        try require("picker.limitedAtPercent", picker.limitedAtPercent, 1...100)
        try require("picker.minRoomPercent", picker.minRoomPercent, 0...100)
        try require("picker.deadlineSeconds", picker.deadlineSeconds, seconds)
        try require("picker.leaseMinutes", picker.leaseMinutes, minutes)
        try require("picker.expectedRunPercent", picker.expectedRunPercent, 0...100)
        try require(
            "picker.endingSoonAssumeDays", picker.endingSoonAssumeDays, 0...ConfigLimits.days)
        try require("history.retentionDays", config.history.retentionDays, 0...ConfigLimits.days)
        let launch = config.launch
        try require("launch.keepDays", launch.keepDays, 1...ConfigLimits.days)
        let keyPattern = #"\A[A-Za-z][A-Za-z0-9_]{0,63}\z"#
        for key in launch.settingsKeys
        where key.range(of: keyPattern, options: .regularExpression) == nil {
            throw ToolError("launch.settingsKeys holds a name that is not valid.")
        }
        for name in launch.envNames
        where name.range(of: CallerSettings.envNamePattern, options: .regularExpression) == nil {
            throw ToolError("launch.envNames holds a name that is not valid.")
        }
        try CallerSettings.checkLaunchLists(launch)
        var seen = Set<String>()
        var logins = 0
        for account in config.accounts {
            let label = Display.safe(account.label)
            guard isValidLabel(account.label) else {
                throw ToolError(
                    "Label '\(label)' is not valid. Use 1 to 32 lowercase letters, digits or hyphens, starting with a letter or digit."
                )
            }
            guard seen.insert(account.label).inserted else {
                throw ToolError("Label '\(label)' is used twice.")
            }
            guard Kind.all.contains(account.kind) else {
                throw ToolError(
                    "Account '\(label)' has an unknown kind. Use login, token or folder.")
            }
            guard Role.all.contains(account.role) else {
                throw ToolError("Account '\(label)' has an unknown role. Use main or pool.")
            }
            if account.kind == Kind.login { logins += 1 }
            if account.kind == Kind.folder, let context {
                try FolderPaths.requireUsable(context: context, label: account.label)
            }
            if let ends = account.endsAt, !isValidDate(ends) {
                throw ToolError("Account '\(label)': ends must be a date like 2026-12-31.")
            }
            if let created = account.tokenCreatedAt {
                guard account.kind == Kind.token, isValidTimestamp(created) else {
                    throw ToolError("Account '\(label)': tokenCreatedAt is not valid.")
                }
            }
            if let names = account.noLimit,
                names.isEmpty || Set(names).count != names.count
                    || !names.allSatisfy({ WindowName.mayHaveNoLimit.contains($0) })
            {
                let accepted = WindowName.mayHaveNoLimit.sorted().map { "\"\($0)\"" }
                throw ToolError(
                    "Account '\(label)': noLimit must be [\(accepted.joined(separator: ", "))].")
            }
            if let reserve = account.reserve {
                let point = "Account '\(label)': a reserve point's"
                for each in reserve.points {
                    try require("\(point) daysLeft", each.daysLeft, 0...ConfigLimits.days)
                    try require("\(point) maxUsedPercent", each.maxUsedPercent, 0...100)
                }
                try require(
                    "Account '\(label)': the reserve's marginPercent", reserve.marginPercent,
                    0...100)
                if account.role == Role.main && reserve.allowAbove90 != true
                    && reserve.points.contains(where: { $0.maxUsedPercent > 90 })
                {
                    throw ToolError(
                        "Account '\(label)': a reserve point above 90 percent needs allowAbove90.")
                }
            }
        }
        if logins > 1 {
            throw ToolError("Only one login account is allowed: it is the default folder's.")
        }
    }

    /// Refuses a number outside its range with a message that names the field and the range.
    private static func require(_ field: String, _ value: Int, _ range: ClosedRange<Int>) throws {
        guard range.contains(value) else {
            throw ToolError("\(field) must be from \(range.lowerBound) to \(range.upperBound).")
        }
    }
}

/// The upper bounds of the numbers in `config.json` (docs/ARCHITECTURE.md section 7.1).
public enum ConfigLimits {
    /// One week, the range `config set` takes for the refresh interval, caps every span.
    public static let spanMinutes = 10_080
    public static let spanSeconds = spanMinutes * 60
    /// A hundred years caps every count of days.
    public static let days = 36_500
}
