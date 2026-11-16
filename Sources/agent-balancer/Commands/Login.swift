import ArgumentParser
import Core
import Foundation

struct LoginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Sign a token or folder account in. A token is never shown.",
        discussion:
            "A token account runs `claude setup-token`: the browser opens and you approve there. With --paste, you run it yourself and paste the token at a hidden prompt. A folder account starts `claude` in its own folder, or with --browser runs `claude auth login` there."
    )

    @Argument(help: "The label of a token or folder account.") var label: String

    @Flag(name: .long, help: "Paste a token from `claude setup-token` at a hidden prompt.")
    var paste = false

    @Flag(
        name: .long, help: "Folder account: sign in through the browser with `claude auth login`.")
    var browser = false

    func run() throws {
        let context = ToolContext.current()
        try Shared.requireOwnTerminal(context)
        let store = ConfigStore(context: context)
        let before = try store.loadRequired()
        guard let account = before.account(label) else {
            throw ToolError("No account is labelled '\(Display.safe(label))'.")
        }
        if account.kind == Kind.folder {
            guard !paste else {
                throw ToolError("--paste is for token accounts. A folder account signs in itself.")
            }
            try loginFolder(context, account: account)
            return
        }
        guard account.kind == Kind.token else {
            throw ToolError(
                "'\(Display.safe(label))' is not a token or folder account. Sign in to it with `claude`, then run `agent-balancer doctor`."
            )
        }
        guard !browser else {
            throw ToolError("--browser is for folder accounts. A token account uses setup-token.")
        }

        let captured: TokenCapture.Result
        if paste {
            // A piped token would sit in the command text of whatever fed it.
            try Shared.requireTerminal()
            captured = try TokenCapture.pasted(context: context, label: label)
        } else {
            print("Opening the browser. Approve the sign-in there. The token is not shown.")
            fflush(stdout)
            captured = try TokenCapture.capture(
                context: context, label: label, runner: ClaudeRunner(context: context))
        }

        // Saved under the pick lock, so a concurrent add or remove of another label is kept.
        let config = try TokenAccounts.updateConfig(context: context) { config in
            guard let index = config.accounts.firstIndex(where: { $0.label == label }) else {
                throw ToolError("No account is labelled '\(Display.safe(label))'.")
            }
            config.accounts[index].tokenCreatedAt = ISO8601DateFormatter().string(from: Date())
        }
        guard let index = config.accounts.firstIndex(where: { $0.label == label }) else {
            throw ToolError("No account is labelled '\(Display.safe(label))'.")
        }

        print("Saved the token for '\(Display.safe(label))'.")
        if captured.replaced {
            print(
                "Rewrote \(captured.launchFilesRewritten) launch files with the new token. The old token may keep working until its year ends, because no way to cancel one is documented."
            )
        }

        var observations = StatusObservations()
        if captured.replaced { observations.tokenReplaced = [label] }
        // Every save deleted the label's reading, so a limit it showed did not clear.
        observations.readingDropped = [label]
        let result = Refresher(context: context, config: config)
            .refresh(account: config.accounts[index], force: true, fable: .none)
        observations.add([result])
        var failed = false
        switch result.status {
        case .probed(let reading), .fresh(let reading), .usedStored(let reading):
            print("First check: \(RefreshCommand.summary(reading, prefix: "read"))")
        case .failed(let issue):
            print("First check failed. " + Shared.line(issue))
            failed = true
        case .notStarted:
            print("First check did not run.")
            failed = true
        }
        if !failed, let warning = result.duplicate.issue {
            print(Shared.line(warning))
        }
        Shared.rebuildStatus(context, observations: observations)
        if failed { throw ExitCode.failure }
    }

    // MARK: Folder accounts

    private func loginFolder(_ context: ToolContext, account: Account) throws {
        let safe = Display.safe(label, limit: 32)
        let folder = try FolderPaths.configDir(context: context, label: label)
        guard FolderPaths.state(context: context, label: label) == .ready else {
            throw ToolError(
                "The folder of '\(safe)' is missing or is a link. Run `agent-balancer doctor`.",
                code: .checkFailed)
        }
        // A folder that is not linked would run with none of the shared hooks.
        switch Verifier.linkFacts(context: context, label: label).verdict {
        case .notLinked:
            throw ToolError(
                "'\(safe)' is not linked. Run `agent-balancer link \(label)` in Terminal first.",
                code: .notLinked)
        case .broken:
            throw ToolError(Messages.linkBroken(label))
        case .ok: break
        }
        let runner = ClaudeRunner(context: context)
        let wasSignedIn: Bool
        switch AuthStatusReader.read(runner: runner, configDir: folder) {
        case .failed(let issue):
            throw ToolError(issue.text)
        case .status(let status):
            wasSignedIn = status.loggedIn
            // A sign-in the last probe found rejected is signed in again, not refused.
            guard
                !status.loggedIn
                    || StatusBuilder.probeFoundSignInRejected(context: context, account: account)
            else {
                // The sign-in it just read is recorded as any check is, so the status shows it.
                var observations = StatusObservations()
                observations.auth[label] = AuthObservation(
                    FolderKind.evaluate(status, account: account, folder: folder, now: Date()))
                Shared.rebuildStatus(context, observations: observations)
                throw ToolError(
                    "'\(safe)' is already signed in. \(Messages.oneAccountPerFolder)")
            }
        }
        print(Messages.oneAccountPerFolder)
        var arguments: [String] = []
        if browser {
            arguments = ["auth", "login"]
            if let email = account.email {
                guard ConfigValidator.isPlainEmail(email) else {
                    throw ToolError(Messages.emailNotPlain(label), code: .checkFailed)
                }
                arguments += ["--email", email]
            }
            print("Signing in through the browser for '\(safe)'.")
        } else {
            print(
                "Starting claude in the folder of '\(safe)'. Type /login, finish the sign-in, then exit."
            )
        }
        fflush(stdout)
        let exitStatus = try runner.launchAttached(arguments: arguments, configDir: folder)

        var observations = StatusObservations()
        let now = Date()
        let check: AccountCheck
        switch AuthStatusReader.read(runner: runner, configDir: folder) {
        case .failed(let issue):
            print(Shared.line(issue))
            throw ExitCode.failure
        case .status(let status):
            check = FolderKind.evaluate(status, account: account, folder: folder, now: now)
        }
        var observation = AuthObservation(check)
        // New only when the folder was signed out before, or `claude auth login` finished: an
        // interactive run that ends cleanly may never have signed in again.
        observation.newSignIn = !wasSignedIn || (browser && exitStatus == 0)
        observations.auth[label] = observation
        Shared.rebuildStatus(context, observations: observations)
        guard check.signedIn else {
            print(
                Shared.line(check.issues.first ?? Issue(.loginRejected, .error, "Not signed in.")))
            throw ExitCode.failure
        }
        if let failure = check.issues.first(where: {
            $0.code == .checkFailed && $0.severity == .error
        }) {
            print(Shared.line(failure))
            throw ExitCode.failure
        }
        if let wrong = check.issues.first(where: { $0.code == .wrongAccount }) {
            print(Shared.line(wrong))
            print(Messages.signExpectedBackIn)
            throw ExitCode.failure
        }
        // Signed in before, and this run cannot show a new sign-in: the rejection stands.
        if wasSignedIn && !observation.newSignIn {
            print(Shared.line(Issue(.loginRejected, .error, Messages.signInNotRenewed(label))))
            throw ExitCode.failure
        }
        if account.email == nil {
            print("Signed in. No expected email is set for '\(safe)'.")
        } else {
            print("Signed in. The folder holds the expected account.")
        }
        // The first sign-in fixes the plan the account is expected to keep.
        if account.expectedPlanTier == nil, let tier = check.planTier {
            try Shared.recordExpectedTiers(
                context: context, tiers: [label: (tier, check.emailDigest)])
        }
        for issue in check.issues { print(Shared.line(issue)) }
    }
}
