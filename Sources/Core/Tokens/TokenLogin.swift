import Foundation

/// `login` for a token account (docs/ARCHITECTURE.md section 4A.4): the checks of every step
/// after the sign-in, the sign-in or the paste, the save, the first check and the status rebuild.
/// Each step declares what it does under the data folder once, as a plan; the checks of each
/// plan run before the sign-in starts or a pasted token is read, and the step runs under the same
/// plan, so no refusal comes once a token exists. Once the token is saved, a step that does not
/// finish says so and the run goes on; nothing after the save asks for a new sign-in, except a
/// rejection of the new token by the service, whose text asks for one `refresh` and a new sign-in
/// only if the service rejects the token again.
public enum TokenLogin {
    /// What a login did once its token was saved.
    public struct Outcome: Sendable {
        public let captured: TokenCapture.Result
        public let firstCheck: AccountRefresh
        /// Each step after the save that did not finish, with what it leaves and its fix.
        public let unfinished: [String]
    }

    /// `login <label>`: runs `claude setup-token` once every check has passed, `announce` just
    /// before it starts. `saved` hears the save before the first check runs.
    public static func signIn(
        context: ToolContext, label: String, runner: ClaudeRunner, announce: () -> Void,
        saved: (TokenCapture.Result) -> Void
    ) throws -> Outcome {
        try run(context: context, label: label, saved: saved) { ready in
            try TokenCapture.capture(
                context: context, label: label, runner: runner, ready: ready, announce: announce)
        }
    }

    /// `login <label> --paste`: reads the token at a hidden prompt once every check has passed.
    public static func paste(
        context: ToolContext, label: String, saved: (TokenCapture.Result) -> Void
    ) throws -> Outcome {
        try paste(context: context, label: label, terminal: .standardInput, saved: saved)
    }

    static func paste(
        context: ToolContext, label: String, terminal: PasteTerminal,
        saved: (TokenCapture.Result) -> Void
    ) throws -> Outcome {
        try run(context: context, label: label, saved: saved) { ready in
            try TokenCapture.pasted(
                context: context, label: label, terminal: terminal, ready: ready)
        }
    }

    /// The plans of the steps after the sign-in, in the order they run: the token save, the
    /// first check and the status rebuild that records it.
    static func plans(context: ToolContext, account: Account, config: Config)
        -> [NoFollowWriter.Plan]
    {
        [
            TokenAccounts.savePlan(context: context, label: account.label, config: config),
            Refresher(context: context, config: config).checkPlan(account: account),
            StatusBuilder.rebuildPlan(context: context),
        ]
    }

    /// The checks of every step after the sign-in, before anything is written: first the rules
    /// of the config save the token save makes, which check every folder account's folders, so a
    /// refused one is named with its account and fix as that save would name it; then each step's
    /// plan in the order the steps run. The config keeps the label's `tokenCreatedAt` until the
    /// token save replaces it, so a `login` that ends before a token is saved changes nothing.
    /// Returns the registry as checked, read with the call the token save reads it with.
    static func requireReady(context: ToolContext, label: String) throws -> Config {
        let found = try ConfigStore(context: context).loadRequired()
        guard let account = found.account(label), account.kind == Kind.token else {
            throw ToolError("No token account is labelled '\(Display.safe(label))'.")
        }
        try ConfigValidator.validate(found, context: context)
        let writer = NoFollowWriter(root: context.dataRoot)
        for plan in plans(context: context, account: account, config: found) {
            try writer.require(plan)
        }
        return found
    }

    /// The first check's issue as `login` prints it once the new token is saved. A rejection by
    /// the service says to run `refresh` once and to sign in again only if the service rejects
    /// the token again, since a rejection can pass; a token file the check could not use names
    /// `doctor`, since the token was saved and a new sign-in would end the same way. Any other
    /// issue is printed as it is.
    public static func afterSave(_ issue: Issue, label: String) -> Issue {
        switch issue.code {
        case .loginRejected:
            return Issue(.loginRejected, issue.severity, Messages.newTokenRejected(label))
        case .tokenMissing where issue.text.contains("agent-balancer login"):
            return Issue(.tokenMissing, issue.severity, Messages.savedTokenNotUsable(label))
        default:
            return issue
        }
    }

    private static func run(
        context: ToolContext, label: String, saved: (TokenCapture.Result) -> Void,
        take: (_ ready: () throws -> Void) throws -> TokenCapture.Result
    ) throws -> Outcome {
        var checked: Config?
        let captured = try take { checked = try requireReady(context: context, label: label) }
        saved(captured)
        let notRun = AccountRefresh(label: label, status: .notStarted, fable: .notRun)
        // The registry as the save left it, or as it was checked when it cannot be read now.
        guard let config = (try? ConfigStore(context: context).loadRequired()) ?? checked,
            let account = config.account(label)
        else {
            return Outcome(captured: captured, firstCheck: notRun, unfinished: captured.unfinished)
        }
        var observations = StatusObservations()
        if captured.replaced { observations.tokenReplaced = [label] }
        // Every save deleted the label's reading, so a limit it showed did not clear.
        observations.readingDropped = [label]
        observations.newToken = [label]
        let result = Refresher(context: context, config: config)
            .refresh(account: account, force: true, fable: .none) { checked in
                // Recorded while the probe lock is held, so no later probe of the token comes first.
                observations.add([checked])
                StatusBuilder.rebuildQuietly(context: context, observations: observations)
            }
        return Outcome(captured: captured, firstCheck: result, unfinished: captured.unfinished)
    }
}
