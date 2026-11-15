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
                config set <label> email|ends|ending-soon|label <value>
                config set refresh.backgroundMinutes <n>
                An account keeps one end marker: `ends <date>` clears ending-soon, `ending-soon
                true` clears the date, and `ends none` clears both.
                """)

        @Argument(parsing: .remaining) var words: [String] = []

        func run() throws {
            let context = ToolContext.current()
            try Shared.requireOwnTerminal(context)
            var lines: [String] = []
            // Under the pick lock like every registry writer, so an add, remove or role change
            // saved at the same moment is kept and a remove never sees a rename half way.
            let config = try TokenAccounts.updateConfig(context: context, backup: true) { config in
                lines = try Self.change(words, in: &config)
            }
            for line in lines { print(line) }
            var observations = StatusObservations()
            // A new email is checked as `status` checks it, since no check of the old one counts.
            if words.count == 3, words[1] == "email", let account = config.account(words[0]),
                let handler = AccountKinds.handler(for: account.kind)
            {
                let check = handler.check(
                    account: account, runner: ClaudeRunner(context: context), now: Date())
                observations.auth[account.label] = AuthObservation(check)
            }
            Shared.rebuildStatus(context, observations: observations)
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
                    "Usage: config set <label> email|ends|ending-soon|label <value>, or config set refresh.backgroundMinutes <n>."
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
            switch field {
            case "email":
                guard value.contains("@"), !value.contains(" ") else {
                    throw ToolError("That is not an email address.")
                }
                account.email = value
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
            default:
                throw ToolError(
                    "Unknown field '\(Display.safe(field))'. Use email, ends, ending-soon or label."
                )
            }
            config.accounts[index] = account
            var lines = ["Updated \(field) for '\(Display.safe(label))'."]
            if let cleared {
                lines.append("Also cleared \(cleared): an account keeps one end marker.")
            }
            return lines
        }
    }
}
