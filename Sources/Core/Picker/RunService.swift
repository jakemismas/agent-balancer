import Foundation

/// What `run` hands the command once the checks pass: the launch line and the argument array.
public struct RunLaunch: Sendable {
    public let label: String
    public let leaseId: String
    /// `--settings` and the launch file, then the person's own arguments. The settings pair comes
    /// first so nothing the person typed can take it or turn it into prompt text.
    public let arguments: [String]
    /// The literal launch line: `claude`, `launchArgs`, then the person's arguments. It names the
    /// launch file and never holds a token.
    public let line: String
}

/// The first argument names a `claude` subcommand: `run` starts a session, and such a verb would
/// act on the default login instead.
enum ClaudeSubcommands {
    static let names: Set<String> = [
        "add", "agents", "attach", "auth", "config", "doctor", "install", "kill", "list", "login",
        "logout", "logs", "mcp", "plugin", "plugins", "project", "rc", "remote-control", "remove",
        "respawn", "rm", "serve", "setup-token", "status", "stop", "update", "upgrade", "uninstall",
    ]
}

/// `run`: the recipe of `pick` for a person who names the account (docs/ARCHITECTURE.md sections
/// 4A.2, 4A.5 and 5.7). It runs the kind's checks without the reading check, takes a lease and
/// writes one launch file under the pick lock, and starts nothing itself. It never opens the
/// default folder's settings file: it uses the verdict a reader saved (`HookRecord.seenVerdict`).
extension PickService {
    /// Quotes one argument for a printed line so it reads back as one literal in a shell. An
    /// argument with a control character is written in `$'...'` form, so the line is display-safe
    /// too. The tool never hands the line to a shell.
    static func shellQuote(_ text: String) -> String {
        let plain = text.range(of: #"\A[A-Za-z0-9_@%+=:,./-]+\z"#, options: .regularExpression)
        if plain != nil { return text }
        if Display.safe(text, limit: Int.max) == text {
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var out = "$'"
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if Display.safe(String(scalar)) == String(scalar) {
                    out.unicodeScalars.append(scalar)
                } else if scalar.value < 0x80 {
                    out += String(format: "\\x%02x", scalar.value)
                } else if scalar.value <= 0xFFFF {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out += String(format: "\\U%08x", scalar.value)
                }
            }
        }
        return out + "'"
    }

    static func hasSettingsFlag(_ arguments: [String]) -> Bool {
        arguments.contains { $0 == "--settings" || $0.hasPrefix("--settings=") }
    }

    /// The refusals that depend on the arguments alone. Nothing is written before they pass.
    static func checkRunArguments(_ arguments: [String]) throws {
        // Every recipe carries exactly one --settings, so the person's own would be a second one.
        if hasSettingsFlag(arguments) {
            throw ToolError(
                "Pass no --settings to run. It adds the account's own settings file itself.")
        }
        if let first = arguments.first, ClaudeSubcommands.names.contains(first) {
            throw ToolError(
                "run starts a session, and '\(first)' is a claude command. Start with an option or a longer prompt."
            )
        }
    }

    /// A line that is printed must not carry a token-shaped argument back to the screen.
    static func checkPrintableArguments(_ arguments: [String]) throws {
        if arguments.contains(where: { Scrubber.tokenPass($0) != $0 }) {
            throw ToolError("An argument looks like a token, so no line is printed for it.")
        }
    }

    private func checkedAccount(label: String, arguments: [String]) throws -> (Config, Account) {
        let config = try ConfigStore(context: context).loadRequired()
        guard ConfigValidator.isValidLabel(label),
            let account = config.account(label)
        else { throw ToolError("No account is labelled '\(Display.safe(label, limit: 32))'.") }
        try Self.checkRunArguments(arguments)
        return (config, account)
    }

    /// The line to type in your own terminal, for a chat shell. It reads the config and nothing
    /// else: no token, no settings file, no lease, no launch file, no process.
    public func chatShellLine(label: String, arguments: [String]) throws -> String {
        _ = try checkedAccount(label: label, arguments: arguments)
        try Self.checkPrintableArguments(arguments)
        let rest =
            arguments.isEmpty ? "" : " -- " + arguments.map(Self.shellQuote).joined(separator: " ")
        return "agent-balancer run \(label)" + rest
    }

    /// `printOnly` is a typing caller: the line is typed in a terminal whose environment this tool
    /// does not control, so the ambient rule and the inherited token or key rule apply as for a
    /// typed `pick`.
    public func prepareRun(label: String, arguments: [String], printOnly: Bool = false) throws
        -> RunLaunch
    {
        let (config, account) = try checkedAccount(label: label, arguments: arguments)
        let runner = ClaudeRunner(context: context)
        let ambient = AmbientState(context.ambient)
        if printOnly {
            try Self.checkPrintableArguments(arguments)
            if ambient.key {
                throw ToolError(
                    "A token or API key is set in this shell, so a line typed here would not use '\(label)'. Run `agent-balancer run \(label)` without --print-command."
                )
            }
        } else {
            _ = try runner.locate()
        }

        let seen = HookRecord(context: context).seenVerdict()
        var observations = StatusObservations()
        // The person's child environment drops the protected group, so an ambient folder or key
        // variable cannot change where a started session lands.
        let request = PickRequest(caller: printOnly ? .typed : .launcher)
        if let skip = preSkip(
            account, request: request, ambientConfigDir: printOnly && ambient.configDir,
            settingsIssue: seen.issue, carriesKey: seen.carriesKey, runner: runner,
            observations: &observations)
        {
            if skip.code == .tokenMissing {
                throw ToolError(Messages.tokenMissing(label), code: .tokenMissing)
            }
            throw ToolError(skip.reason, code: skip.code)
        }

        let writer = NoFollowWriter(root: context.dataRoot)
        guard
            let lock = try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: lockWaitSeconds)
        else { throw ToolError("Another pick is running. Try again in a moment.") }
        defer { lock.release() }

        let now = clock()
        let leaseStore = LeaseStore(context: context)
        var leases = try leaseStore.current(now: now, leaseMinutes: config.picker.leaseMinutes)
        let id = freshLeaseId(leases)
        let path = try LaunchFiles.fileURL(context: context, label: label, leaseId: id).path
        let launchArgs = try Recipe.launchArgs(settingsPath: path)
        do {
            _ = try LaunchFiles.create(
                context: context, account: account, leaseId: id, caller: .none)
        } catch let error as ToolError where error.code == .tokenMissing {
            throw ToolError(Messages.tokenMissing(label), code: .tokenMissing)
        }
        do {
            leases.append(Lease(id: id, label: label, model: "default", at: now))
            try leaseStore.save(leases)
        } catch {
            LaunchFiles.discard(context: context, label: label, leaseId: id)
            throw error
        }
        logPick(
            time: now, model: "default", label: label, leaseId: id, reason: "run by name",
            writer: writer)
        lock.release()
        StatusBuilder.rebuildQuietly(context: context, observations: observations)

        let line =
            (["claude", launchArgs] + arguments.map(Self.shellQuote)).joined(separator: " ")
        return RunLaunch(
            label: label, leaseId: id, arguments: ["--settings", path] + arguments, line: line)
    }

    /// Drops the launch file and the lease of a run whose session could not be started, so no
    /// token copy is left behind.
    public func abandon(_ launch: RunLaunch) {
        let writer = NoFollowWriter(root: context.dataRoot)
        guard
            let lock = try? writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: lockWaitSeconds)
        else {
            LaunchFiles.discard(context: context, label: launch.label, leaseId: launch.leaseId)
            return
        }
        defer { lock.release() }
        LaunchFiles.discard(context: context, label: launch.label, leaseId: launch.leaseId)
        let store = LeaseStore(context: context)
        let minutes = (try? ConfigStore(context: context).loadRequired().picker.leaseMinutes) ?? 0
        if minutes > 0, let open = try? store.current(now: clock(), leaseMinutes: minutes) {
            try? store.save(open.filter { $0.id != launch.leaseId })
        }
    }
}
