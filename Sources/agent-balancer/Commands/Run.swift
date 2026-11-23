import ArgumentParser
import Core
import Foundation

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start Claude Code on one account, with that account's launch file.")

    @Flag(name: .customLong("print-command"), help: "Print the launch line and start nothing.")
    var printCommand = false

    @Argument(help: "The label of the account.") var label: String

    @Argument(
        parsing: .postTerminator, help: "Arguments for claude, after a double dash.")
    var arguments: [String] = []

    func run() throws {
        let context = ToolContext.current()
        let service = PickService(context: context)
        // A chat shell gets the line to type in your own terminal and nothing else: no launch file,
        // no lease, no token read and no session, with or without --print-command.
        if context.inChatShell {
            print(try service.chatShellLine(label: label, arguments: arguments))
            throw ToolError(Messages.chatShellRefusal)
        }
        let launch = try service.prepareRun(
            label: label, arguments: arguments, printOnly: printCommand)

        if printCommand {
            print(launch.line)
            return
        }
        let status: Int32
        do {
            status = try ClaudeRunner(context: context).launchAttached(
                arguments: launch.arguments, configDir: launch.configDir)
        } catch {
            throw service.abandoned(launch, after: error)
        }
        if status != 0 { throw ExitCode(status) }
    }
}
