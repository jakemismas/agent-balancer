import ArgumentParser
import Core
import Foundation

struct LoginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Sign a token account in, or replace its token. The token is never shown.",
        discussion:
            "Runs `claude setup-token`: the browser opens and you approve there. With --paste, you run it yourself and paste the token at a hidden prompt."
    )

    @Argument(help: "The label of a token account.") var label: String

    @Flag(name: .long, help: "Paste a token from `claude setup-token` at a hidden prompt.")
    var paste = false

    func run() throws {
        let context = ToolContext.current()
        try Shared.requireOwnTerminal(context)
        let store = ConfigStore(context: context)
        let before = try store.loadRequired()
        guard let account = before.account(label) else {
            throw ToolError("No account is labelled '\(Display.safe(label))'.")
        }
        guard account.kind == Kind.token else {
            throw ToolError(
                "'\(Display.safe(label))' is not a token account. Sign in to it with `claude`, then run `agent-balancer doctor`."
            )
        }

        let captured: TokenCapture.Result
        if paste {
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
        }
        if !failed, let warning = result.duplicate.issue {
            print(Shared.line(warning))
        }
        Shared.rebuildStatus(context, observations: observations)
        if failed { throw ExitCode.failure }
    }
}
