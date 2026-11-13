import ArgumentParser
import Core
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Check the setup and each account's sign-in state.")

    func run() throws {
        let context = ToolContext.current()
        let store = ConfigStore(context: context)
        guard let config = try store.load() else {
            print(Messages.notSetUp)
            return
        }
        var failed = false

        let runner = ClaudeRunner(context: context)
        do {
            let exe = try runner.locate()
            print("claude: \(Display.safe(context.display(exe)))")
            if let version = try? runner.run(arguments: ["--version"], timeout: 30),
                !version.timedOut,
                version.status == 0
            {
                let first =
                    version.stdout.split(separator: "\n").first.map(String.init) ?? "unknown"
                print("version: \(Display.safe(Scrubber.scrubText(first)))")
            } else {
                print("version: could not be read")
                failed = true
            }
        } catch let error as ToolError {
            print(Shared.line(Issue(.checkFailed, .error, error.message)))
            failed = true
        }

        if !config.probe.safeMode {
            print("Note: probe.safeMode is off, so each probe runs the folder's hooks once.")
        }

        let now = Date()
        for account in config.accounts {
            print(
                "account \(Display.safe(account.label)) (\(Display.safe(account.kind)), \(Display.safe(account.role)))"
            )
            guard let handler = AccountKinds.handler(for: account.kind) else {
                print("  sign-in: not checked in this version")
                continue
            }
            let check = handler.check(account: account, runner: runner, now: now)
            if check.signedIn {
                print("  sign-in: signed in")
                print("  plan: \(Display.safe(check.planTier ?? "unknown"))")
                if let expires = check.loginExpiresAt {
                    print("  login expires: \(LoginKind.shortDate(expires))")
                }
            }
            for issue in check.issues {
                print("  " + Shared.line(issue))
            }
            if check.hasError { failed = true }
            if account.kind == Kind.folder {
                switch Verifier.linkFacts(context: context, label: account.label).verdict {
                case .ok:
                    print("  links: intact")
                case .notLinked:
                    print(
                        "  "
                            + Shared.line(
                                Issue(.notLinked, .error, Messages.notLinked(account.label))))
                    failed = true
                case .broken(let detail):
                    print(
                        "  "
                            + Shared.line(
                                Issue(
                                    .settingsChanged, .error,
                                    Messages.linkBroken(account.label) + " "
                                        + Display.safe(detail, limit: 120))))
                    failed = true
                }
                print("  trust: \(Messages.trustStep)")
                print("  note: \(Messages.notCarriedOver)")
            }
        }
        print("session folder: \(SessionFolder.describe(context: context, config: config))")

        for label in TokenAccounts.labelsWithoutAccount(context: context, config: config) {
            print(
                "Warning: a token file is saved for '\(Display.safe(label))', which has no account. Run `agent-balancer remove \(Display.safe(label))` in Terminal to delete it."
            )
        }

        let temporaries = TokenAccounts.writerLeftovers(context: context)
        if temporaries > 0 {
            print(
                "Warning: \(temporaries) temporary files from a write that stopped part way may hold a token. Run `agent-balancer refresh` in Terminal to delete them."
            )
        }

        let sessions = SessionsReader.read(context: context)
        if !sessions.clean {
            print("sessions: some session records could not be read, so in-use is unknown")
        }
        for session in sessions.live
        where session.refs.contains(where: { !LaunchFiles.exists(context: context, ref: $0) }) {
            print(
                "Warning launch_file_missing: session \(Display.safe(String(session.id.prefix(8)), limit: 8)) names a launch file that is gone."
            )
        }

        let launch = DoctorChecks.launchFiles(context: context, snapshot: sessions, now: now)
        if let oldest = launch.oldestAge {
            print(
                "launch files: \(launch.count), oldest \(DoctorChecks.describe(age: oldest)) old")
        } else {
            print("launch files: 0")
        }
        if let service = DoctorChecks.syncedFolder(context: context) {
            print(
                "Warning: the data folder sits in \(service). Tokens and launch files would sync to other devices. Move your home data out of it."
            )
        }

        let hooks = HookRecord(context: context)
        do {
            let facts = try hooks.readSettings()
            switch hooks.status(current: facts) {
            case .missing:
                print(Shared.line(Issue(.settingsChanged, .error, Messages.hookRecordMissing)))
                failed = true
            case .changed:
                print(Shared.line(Issue(.settingsChanged, .error, Messages.settingsChanged)))
                failed = true
            case .matches(let added):
                let extra = added > 0 ? " (\(added) hook entries added since)" : ""
                print("hooks: match the record\(extra)")
            }
            if facts.carriesKey {
                print(Shared.line(Issue(.keyInSettings, .warning, Messages.keyInSettings)))
            }
        } catch {
            print(
                Shared.line(
                    Issue(.settingsChanged, .error, "settings.json could not be read or parsed.")))
            failed = true
        }

        let protectedNames = context.ambient.keys.filter(ProtectedEnv.isProtected).sorted()
        for name in protectedNames {
            let shown = Display.safe(Scrubber.scrubText(name), limit: 64)
            print("Warning: \(shown) is set in this shell. Child processes never receive it.")
        }

        if failed { throw ExitCode.failure }
    }
}
