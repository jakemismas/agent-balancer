import ArgumentParser
import Core
import Foundation

struct AgentBalancer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-balancer",
        abstract: "Spread Claude Code work across your subscription accounts.",
        version: Version.current,
        subcommands: [
            InitCommand.self, DoctorCommand.self, ConfigCommand.self, LinkCommand.self,
            RefreshCommand.self, PickCommand.self, StatusCommand.self, EventsCommand.self,
            HistoryCommand.self, AddCommand.self, LoginCommand.self, RemoveCommand.self,
        ]
    )
}

// Files the tool makes are private to the user.
umask(0o077)
AgentBalancer.main()
