import Foundation

if CommandLine.arguments.contains("--render") || CommandLine.arguments.contains("--iconset") {
    RenderMode.run(arguments: CommandLine.arguments)
} else {
    AgentBalancerBarApp.main()
}
