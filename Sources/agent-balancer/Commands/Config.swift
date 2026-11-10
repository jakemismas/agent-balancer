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
            let store = ConfigStore(context: context)
            var config = try store.loadRequired()
            guard let index = config.accounts.firstIndex(where: { $0.label == label }) else {
                throw ToolError("No account is labelled '\(Display.safe(label))'.")
            }
            config.accounts[index].role = Role.main
            if config.accounts[index].reserve == nil { config.accounts[index].reserve = .standard }
            try store.save(config, backup: true)
            let reserve = config.accounts[index].reserve ?? .standard
            print("'\(Display.safe(label))' is the main account. Reserve: \(reserve.summary).")
        }
    }

    struct ClearMain: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear-main", abstract: "Take the main role off an account.")

        @Argument var label: String

        func run() throws {
            let context = ToolContext.current()
            try Shared.requireOwnTerminal(context)
            let store = ConfigStore(context: context)
            var config = try store.loadRequired()
            guard let index = config.accounts.firstIndex(where: { $0.label == label }) else {
                throw ToolError("No account is labelled '\(Display.safe(label))'.")
            }
            config.accounts[index].role = Role.pool
            config.accounts[index].reserve = nil
            try store.save(config, backup: true)
            print("'\(Display.safe(label))' is a pool account.")
        }
    }

    struct SetField: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Change one field.",
            discussion: """
                config set <label> email|ends|ending-soon|label <value>
                config set refresh.backgroundMinutes <n>
                """)

        @Argument(parsing: .remaining) var words: [String] = []

        func run() throws {
            let context = ToolContext.current()
            try Shared.requireOwnTerminal(context)
            let store = ConfigStore(context: context)
            var config = try store.loadRequired()

            if words.count == 2, words[0] == "refresh.backgroundMinutes" {
                guard let minutes = Int(words[1]), minutes >= 1, minutes <= 10_080 else {
                    throw ToolError(
                        "refresh.backgroundMinutes must be a whole number from 1 to 10080.")
                }
                config.refresh.backgroundMinutes = minutes
                try store.save(config, backup: true)
                print("refresh.backgroundMinutes is \(minutes).")
                return
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
            switch field {
            case "email":
                guard value.contains("@"), !value.contains(" ") else {
                    throw ToolError("That is not an email address.")
                }
                config.accounts[index].email = value
            case "ends":
                if value == "none" {
                    config.accounts[index].endsAt = nil
                } else {
                    guard ConfigValidator.isValidDate(value) else {
                        throw ToolError("ends must be a date like 2026-12-31, or none.")
                    }
                    config.accounts[index].endsAt = value
                }
            case "ending-soon":
                guard value == "true" || value == "false" else {
                    throw ToolError("ending-soon must be true or false.")
                }
                config.accounts[index].endingSoon = value == "true" ? true : nil
            case "label":
                guard ConfigValidator.isValidLabel(value) else {
                    throw ToolError(
                        "Label '\(Display.safe(value))' is not valid. Use 1 to 32 lowercase letters, digits or hyphens, starting with a letter or digit."
                    )
                }
                guard config.account(value) == nil || value == label else {
                    throw ToolError("Label '\(Display.safe(value))' is already used.")
                }
                config.accounts[index].label = value
            default:
                throw ToolError(
                    "Unknown field '\(Display.safe(field))'. Use email, ends, ending-soon or label."
                )
            }
            try store.save(config, backup: true)
            print("Updated \(field) for '\(Display.safe(label))'.")
        }
    }
}
