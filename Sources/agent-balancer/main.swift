import ArgumentParser
import Core

struct AgentBalancer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-balancer",
        abstract: "Spread Claude Code work across your subscription accounts.",
        version: Version.current
    )
}

AgentBalancer.main()
