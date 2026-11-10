import Foundation

public enum ConfigValidator {
    public static func isValidLabel(_ label: String) -> Bool {
        label.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }

    public static func isValidDate(_ text: String) -> Bool {
        text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    }

    /// Throws on the first problem found, with a message that names the field and never a value
    /// that could be personal.
    public static func validate(_ config: Config) throws {
        guard config.schemaVersion == Config.currentSchema else {
            throw ToolError(
                "Config schema version \(config.schemaVersion) is not supported. This version reads version \(Config.currentSchema)."
            )
        }
        if config.refresh.backgroundMinutes < 1 {
            throw ToolError("refresh.backgroundMinutes must be at least 1.")
        }
        if config.probe.timeoutSeconds < 1 {
            throw ToolError("probe.timeoutSeconds must be at least 1.")
        }
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
            if account.kind == Kind.folder {
                throw ToolError(
                    "Account '\(label)': the folder kind is not available in this version.")
            }
            guard Role.all.contains(account.role) else {
                throw ToolError("Account '\(label)' has an unknown role. Use main or pool.")
            }
            if account.kind == Kind.login { logins += 1 }
            if let ends = account.endsAt, !isValidDate(ends) {
                throw ToolError("Account '\(label)': ends must be a date like 2026-12-31.")
            }
            if let reserve = account.reserve {
                for point in reserve.points
                where point.daysLeft < 0 || point.maxUsedPercent < 0 || point.maxUsedPercent > 100 {
                    throw ToolError("Account '\(label)': a reserve point is out of range.")
                }
                if reserve.marginPercent < 0 || reserve.marginPercent > 100 {
                    throw ToolError("Account '\(label)': the reserve margin is out of range.")
                }
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
}
