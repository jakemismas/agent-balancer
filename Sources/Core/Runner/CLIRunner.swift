import Foundation

/// Starts the agent-balancer command line tool for the menu app and nothing else. The app never
/// runs `claude`. The tool is found only at two fixed paths, after the owner and mode test of
/// docs/ARCHITECTURE.md section 6.2, and no path comes from config or any file.
public struct CLIRunner: Sendable {
    public static let fixedPaths = [
        "/opt/homebrew/bin/agent-balancer", "/usr/local/bin/agent-balancer",
    ]

    public let context: ToolContext
    private let candidates: [URL]

    public init(context: ToolContext) {
        self.init(context: context, candidates: nil)
    }

    /// `candidates` exists for tests that run a fake tool from a temporary folder. Production
    /// code always uses the fixed list.
    init(context: ToolContext, candidates: [URL]?) {
        self.context = context
        self.candidates = candidates ?? Self.fixedPaths.map { URL(fileURLWithPath: $0) }
    }

    /// The paths the lookup tries, for the "not found" card.
    public var triedPaths: [String] { candidates.map { context.display($0) } }

    /// The first candidate that exists, used by the path found there. A candidate whose real
    /// target is not owned by the user or root, or is writable by group or others, is refused.
    public func locate() throws -> URL {
        for candidate in candidates {
            guard let facts = FileFacts.inspect(candidate), facts.isRegularFile else { continue }
            let shown = context.display(candidate)
            guard facts.ownerIsUserOrRoot, !facts.writableByOthers, facts.isExecutable else {
                throw ToolError(
                    "Refused \(shown): it must be an executable owned by you or root and not writable by others.",
                    code: .checkFailed)
            }
            return candidate
        }
        throw ToolError("agent-balancer was not found.", code: .checkFailed)
    }

    /// True when `locate` finds a usable tool.
    public var isAvailable: Bool { (try? locate()) != nil }

    /// Runs the tool with `arguments` in the allowlisted child environment of section 6.2. A
    /// missing or refused tool throws. A timeout is reported in the output, with the child ended.
    public func run(_ arguments: [String], timeout: TimeInterval = 300) throws -> RunOutput {
        let exe = try locate()
        let env = ChildEnvironment.probe(
            context: context, claudeFolder: exe.deletingLastPathComponent(), configDir: nil,
            passProxyEnv: false)
        return try ChildProcess.run(
            executable: exe, program: "agent-balancer", arguments: arguments, environment: env,
            workingDirectory: context.home, timeout: timeout, outputCap: 1_048_576,
            inheritInput: false, rawOutput: nil)
    }
}
