import Core
import Foundation

enum Shared {
    /// Consent commands refuse in a chat shell. The message never suggests unsetting a variable.
    static func requireOwnTerminal(_ context: ToolContext) throws {
        if context.inChatShell { throw ToolError(Messages.chatShellRefusal) }
    }

    static func line(_ issue: Issue) -> String {
        let tag = issue.severity == .error ? "Error" : "Warning"
        return "\(tag) \(issue.code.rawValue): \(Display.safe(issue.text, limit: 400))"
    }

    /// Prompts on the terminal and returns the typed line, or nil at end of input.
    static func ask(_ prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces)
    }

    /// Ends a command that wrote under the data folder: rebuilds `state/status.json`. A failure is
    /// logged and never changes the command's output or exit code.
    static func rebuildStatus(
        _ context: ToolContext, observations: StatusObservations = StatusObservations()
    ) {
        StatusBuilder.rebuildQuietly(context: context, observations: observations)
    }
}
