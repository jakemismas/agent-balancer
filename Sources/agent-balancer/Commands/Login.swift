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
                "'\(Display.safe(label))' is not a token or folder account. Sign in to it with `claude`, then run `agent-balancer refresh`."
            )
        }
        guard !browser else {
            throw ToolError("--browser is for folder accounts. A token account uses setup-token.")
        }

        func saved(_ captured: TokenCapture.Result) {
            print("Saved the token for '\(Display.safe(label))'.")
            if captured.replaced {
                print(
                    "Rewrote \(captured.launchFilesRewritten) launch files with the new token. The old token may keep working until its year ends, because no way to cancel one is documented."
                )
            }
        }
        let outcome: TokenLogin.Outcome
        if paste {
            // A piped token would sit in the command text of whatever fed it.
            try Shared.requireTerminal()
            outcome = try TokenLogin.paste(context: context, label: label, saved: saved)
        } else {
            outcome = try TokenLogin.signIn(
                context: context, label: label, runner: ClaudeRunner(context: context),
                announce: {
                    print("Opening the browser. Approve the sign-in there. The token is not shown.")
                    fflush(stdout)
                }, saved: saved)
        }

        for text in outcome.unfinished { print("Error: " + Display.safe(text, limit: 1200)) }
        var failed = !outcome.unfinished.isEmpty
        // A token the service rejects may need a new sign-in, which the rejection's text says.
        var rejected = false
        let result = outcome.firstCheck
        switch result.status {
        case .probed(let reading), .fresh(let reading), .usedStored(let reading):
            print("First check: \(RefreshCommand.summary(reading, prefix: "read"))")
        case .failed(let issue):
            let shown = TokenLogin.afterSave(issue, label: label)
            print(
                "First check failed. Error \(shown.code.rawValue): "
                    + Display.safe(shown.text, limit: 1200))
            failed = true
            rejected = issue.code == .loginRejected
        case .notStarted:
            print("First check did not run.")
            failed = true
        }
        if !failed, let warning = result.duplicate.issue {
            print(Shared.line(warning))
        }
        if failed {
            if !rejected { print(Messages.tokenSavedNoSignIn(label)) }
            throw ExitCode.failure
        }
    }

    // MARK: Folder accounts

    private func loginFolder(_ context: ToolContext, account: Account) throws {
        let safe = Display.safe(label, limit: 32)
        let folder = try FolderPaths.configDir(context: context, label: label)
        switch FolderPaths.state(context: context, label: label) {
        case .ready: break
        case .missing:
            throw ToolError(FolderPaths.missingText(label), code: .checkFailed)
        case .refused:
            throw ToolError(
                FolderPaths.refusalText(context: context, label: label), code: .checkFailed)
        }
        // A folder that is not linked would run with none of the shared hooks.
        switch Verifier.linkFacts(context: context, label: label).verdict {
        case .notLinked:
            throw ToolError(
                "'\(safe)' is not linked. Run `agent-balancer link \(label)` in Terminal first.",
                code: .notLinked)
        case .broken:
            throw ToolError(Messages.linkBroken(label))
        case .refused(let text):
            throw ToolError(text, code: .checkFailed)
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
        // The plan saved after the sign-in takes the pick lock and meets every folder account's
        // checks, so they run first, through the call the save's own checks use.
        try TokenAccounts.requireConfigUpdatable(
            context: context, config: try ConfigStore(context: context).loadRequired())
        // The status rebuild that records the sign-in is checked first too.
        try StatusBuilder.requireRebuildable(context: context)
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
            do {
                try Shared.recordExpectedTiers(
                    context: context, tiers: [label: (tier, check.emailDigest)])
            } catch {
                let reason = (error as? ToolError)?.message ?? "the config could not be saved."
                let text = Messages.planNotRecorded(label, reason)
                print("Error \(StateCode.checkFailed.rawValue): " + Display.safe(text, limit: 1200))
                throw ExitCode.failure
            }
        }
        for issue in check.issues { print(Shared.line(issue)) }
    }
}
