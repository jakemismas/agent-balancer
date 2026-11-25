import ArgumentParser
import Core
import Foundation

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config", abstract: "Show, check and change the account registry.",
        subcommands: [Show.self, Validate.self, SetMain.self, ClearMain.self, SetField.self])

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show", abstract: "Print the registry. Emails stay hidden by default.")

        @Flag(help: "Show email addresses.") var emails = false

        func run() throws {
            let config = try ConfigStore(context: .current()).loadRequired()
            print("schemaVersion: \(config.schemaVersion)")
            print("sharedSource: \(Display.safe(config.sharedSource))")
            print("probe.safeMode: \(config.probe.safeMode)")
            print("refresh.backgroundMinutes: \(config.refresh.backgroundMinutes)")
            for a in config.accounts {
                print("account \(Display.safe(a.label))")
                print("  kind: \(Display.safe(a.kind))")
                print("  role: \(Display.safe(a.role))")
                if let tier = a.expectedPlanTier { print("  plan: \(Display.safe(tier))") }
                if emails, let email = a.email { print("  email: \(Display.safe(email))") }
                if let ends = a.endsAt {
                    print("  ends: \(Display.safe(String(describing: ends)))")
                }
                if a.endingSoon == true { print("  ending-soon: true") }
                if let names = a.noLimit {
                    print("  no-limit: \(Display.safe(names.joined(separator: ", ")))")
                }
                if let reserve = a.reserve { print("  reserve: \(reserve.summary)") }
            }
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate", abstract: "Check the registry against the rules.")

        func run() throws {
            _ = try ConfigStore(context: .current()).loadRequired()
            print("Config is valid.")
        }
    }

    struct SetMain: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-main", abstract: "Make an account the main account.")

        @Argument var label: String

        func run() throws {
            let context = ToolContext.current()
            try Shared.requireOwnTerminal(context)
            // Under the pick lock, so the role never changes while `remove` checks it and deletes.
            let config = try TokenAccounts.updateConfig(context: context, backup: true) { config in
                guard let index = config.accounts.firstIndex(where: { $0.label == label }) else {
                    throw ToolError("No account is labelled '\(Display.safe(label))'.")
                }
                config.accounts[index].role = Role.main
                if config.accounts[index].reserve == nil {
                    config.accounts[index].reserve = .standard
                }
            }
            let reserve = config.account(label)?.reserve ?? .standard
            print("'\(Display.safe(label))' is the main account. Reserve: \(reserve.summary).")
            Shared.rebuildStatus(context)
        }
    }

    struct ClearMain: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear-main", abstract: "Take the main role off an account.")

        @Argument var label: String

        func run() throws {
            let context = ToolContext.current()
            try Shared.requireOwnTerminal(context)
            try TokenAccounts.updateConfig(context: context, backup: true) { config in
                guard let index = config.accounts.firstIndex(where: { $0.label == label }) else {
                    throw ToolError("No account is labelled '\(Display.safe(label))'.")
                }
                config.accounts[index].role = Role.pool
                config.accounts[index].reserve = nil
            }
            print("'\(Display.safe(label))' is a pool account.")
            Shared.rebuildStatus(context)
        }
    }

    struct SetField: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Change one field.",
            discussion: """
                config set <label> email|ends|ending-soon|label|no-limit <value>
                config set refresh.backgroundMinutes <n>
                An account keeps one end marker: `ends <date>` clears ending-soon, `ending-soon
                true` clears the date, and `ends none` clears both. `no-limit five_hour` says the
                account's plan has no 5-hour limit; `no-limit none` takes it back.
                """)

        @Argument(parsing: .remaining) var words: [String] = []

        func run() throws {
            let context = ToolContext.current()
            try Shared.requireOwnTerminal(context)
            var lines: [String] = []
            var observations = StatusObservations()
            var probeLocks: [FileLock] = []
            defer { for lock in probeLocks { lock.release() } }
            var signInChanged = false
            var move: () throws -> Void = {}
            // Under the pick lock like every registry writer, so an add, remove or role change
            // saved at the same moment is kept and a remove never sees a rename half way.
            let config = try TokenAccounts.updateConfig(context: context, backup: true) { config in
                let before = config.accounts.first { $0.label == words.first }
                lines = try Self.change(words, in: &config)
                guard let before,
                    let after = config.accounts.first(where: { $0.accountKey == before.accountKey })
                else { return }
                if Self.changesSignIn(from: before, to: after) {
                    probeLocks = try TokenAccounts.takeProbeLocks(
                        context: context, labels: [before.label], config: config)
                    // A reading taken for the old email would judge the new sign-in.
                    try ReadingStore(context: context).delete(label: before.label)
                    observations.readingDropped = [before.label]
                    signInChanged = true
                } else if after.label != before.label {
                    probeLocks = try TokenAccounts.takeProbeLocks(
                        context: context, labels: [before.label, after.label], config: config)
                    move = try TokenAccounts.moveLabel(
                        context: context, from: before.label, to: after.label)
                }
            } afterSave: {
                // Only a saved rename moves the files, so a refused save leaves them in place.
                try move()
            }
            for lock in probeLocks { lock.release() }
            for line in lines { print(line) }
            // What the check finds is recorded however the command ends, after any plan is saved.
            defer { Shared.rebuildStatus(context, observations: observations) }
            // A new email is checked as `status` checks it, since no check of the old one counts.
            if words.count == 3, words[1] == "email", let account = config.account(words[0]),
                let handler = AccountKinds.handler(for: account.kind)
            {
                let check = handler.check(
                    account: account, runner: ClaudeRunner(context: context), now: Date())
                let observation = AuthObservation(check)
                observations.auth[account.label] = observation
                // The first check that places the new sign-in fixes the plan it is expected to keep.
                if signInChanged, account.expectedPlanTier == nil, observation.seen == .signedIn,
                    let tier = check.planTier
                {
                    try Shared.recordExpectedTiers(
                        context: context, tiers: [account.label: (tier, check.emailDigest)])
                }
            }
        }

        /// Whether a change gives a `login` or `folder` account an email its sign-in check reads as
        /// another one: it compares emails without letter case.
        static func changesSignIn(from before: Account, to after: Account) -> Bool {
            [Kind.login, Kind.folder].contains(before.kind)
                && before.email?.lowercased() != after.email?.lowercased()
        }

        /// Applies one change to `config` and returns the lines to print.
        static func change(_ words: [String], in config: inout Config) throws -> [String] {
            if words.count == 2, words[0] == "refresh.backgroundMinutes" {
                guard let minutes = Int(words[1]), minutes >= 1, minutes <= 10_080 else {
                    throw ToolError(
                        "refresh.backgroundMinutes must be a whole number from 1 to 10080.")
                }
                config.refresh.backgroundMinutes = minutes
                return ["refresh.backgroundMinutes is \(minutes)."]
            }
            guard words.count == 3 else {
                throw ToolError(
                    "Usage: config set <label> email|ends|ending-soon|label|no-limit <value>, or config set refresh.backgroundMinutes <n>."
                )
            }
            let label = words[0]
            let field = words[1]
            let value = words[2]
            guard let index = config.accounts.firstIndex(where: { $0.label == label }) else {
                throw ToolError("No account is labelled '\(Display.safe(label))'.")
            }
            var account = config.accounts[index]
            var cleared: String?
            var forgotten: String?
            switch field {
            case "email":
                guard value.contains("@"), !value.contains(" ") else {
                    throw ToolError("That is not an email address.")
                }
                let old = account
                account.email = value
                // A plan recorded for the old sign-in says nothing about the new one.
                if changesSignIn(from: old, to: account) {
                    account.expectedPlanTier = nil
                    if account.noLimit != nil { forgotten = "no-limit" }
                    account.noLimit = nil
                }
            case "ends":
                if value != "none" {
                    guard ConfigValidator.isTodayOrLater(value) else {
                        throw ToolError(
                            "ends must be today or a later date like 2026-12-31, or none.")
                    }
                }
                if account.endingSoon == true { cleared = "ending-soon" }
                account.endsAt = value == "none" ? nil : value
                account.endingSoon = nil
            case "ending-soon":
                guard value == "true" || value == "false" else {
                    throw ToolError("ending-soon must be true or false.")
                }
                if value == "true" {
                    if account.endsAt != nil { cleared = "ends" }
                    account.endsAt = nil
                    account.endingSoon = true
                } else {
                    account.endingSoon = nil
                }
            case "label":
                // A token account's files carry its label, so a rename would strand the token.
                guard account.kind != Kind.token else {
                    throw ToolError(
                        "A token account cannot be renamed. Run `agent-balancer remove \(Display.safe(label))`, then `agent-balancer add \(Display.safe(value))` and `agent-balancer login \(Display.safe(value))`."
                    )
                }
                // A rename would leave the folder, with its sign-in and links, under the old name.
                guard account.kind != Kind.folder else {
                    throw ToolError(
                        "A folder account cannot be renamed: its folder is named for the label. Nothing was changed."
                    )
                }
                guard ConfigValidator.isValidLabel(value) else {
                    throw ToolError(
                        "Label '\(Display.safe(value))' is not valid. Use 1 to 32 lowercase letters, digits or hyphens, starting with a letter or digit."
                    )
                }
                guard config.account(value) == nil || value == label else {
                    throw ToolError("Label '\(Display.safe(value))' is already used.")
                }
                account.label = value
            case "no-limit":
                if value == "none" {
                    account.noLimit = nil
                } else if WindowName.mayHaveNoLimit.contains(value) {
                    account.noLimit = [value]
                } else {
                    let names = WindowName.mayHaveNoLimit.sorted().joined(separator: ", ")
                    throw ToolError("no-limit must be \(names) or none.")
                }
            default:
                throw ToolError(
                    "Unknown field '\(Display.safe(field))'. Use email, ends, ending-soon, label or no-limit."
                )
            }
            config.accounts[index] = account
            var lines = ["Updated \(field) for '\(Display.safe(label))'."]
            if let cleared {
                lines.append("Also cleared \(cleared): an account keeps one end marker.")
            }
            if let forgotten {
                lines.append("Also cleared \(forgotten): it was set for the old sign-in.")
            }
            return lines
        }
    }
}
