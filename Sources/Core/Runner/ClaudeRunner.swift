import Foundation

public struct RunOutput: Sendable {
    public let status: Int32
    /// Token pass applied to the whole captured buffer.
    public let stdout: String
    /// Both scrub passes applied to the whole captured buffer.
    public let stderr: String
    public let timedOut: Bool
    public let truncated: Bool
}

public enum LaunchEnvironment: Sendable {
    case probe
    case person
}

/// Collects a child's output up to a cap and discards the rest, so the child never blocks.
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int
    private var over = false

    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let room = cap - data.count
        if chunk.count <= room {
            data.append(chunk)
        } else {
            if room > 0 { data.append(chunk.prefix(room)) }
            over = true
        }
    }

    func snapshot() -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, over)
    }
}

/// Starts `claude` and nothing else. A `Process` with an argument array, never a shell.
public struct ClaudeRunner: Sendable {
    public let context: ToolContext
    private let candidates: [URL]

    public init(context: ToolContext) {
        self.init(context: context, candidates: nil)
    }

    /// `candidates` exists for tests that need a tree with no `claude` in it. Production code
    /// always uses the fixed list.
    init(context: ToolContext, candidates: [URL]?) {
        self.context = context
        self.candidates =
            candidates ?? [
                context.home.appendingPathComponent(".local/bin/claude"),
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                URL(fileURLWithPath: "/usr/local/bin/claude"),
            ]
    }

    /// The first candidate that exists. It is used by the path found there, not by its real
    /// target. A candidate whose real target is not owned by the user or root, or is writable by
    /// group or others, is refused. The parent folder gets the same test only for `~/.local/bin`.
    public func locate() throws -> URL {
        let localBin = context.home.appendingPathComponent(".local/bin").standardizedFileURL.path
        for candidate in candidates {
            guard let facts = FileFacts.inspect(candidate), facts.isRegularFile else { continue }
            let shown = context.display(candidate)
            guard facts.ownerIsUserOrRoot, !facts.writableByOthers, facts.isExecutable else {
                throw ToolError(
                    "Refused \(shown): it must be an executable owned by you or root and not writable by others.",
                    code: .checkFailed)
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.standardizedFileURL.path == localBin {
                guard let p = FileFacts.inspect(parent), p.ownerIsUserOrRoot, !p.writableByOthers
                else {
                    throw ToolError(
                        "Refused \(shown): its folder must be owned by you and not writable by others.",
                        code: .checkFailed)
                }
            }
            return candidate
        }
        throw ToolError(
            "The claude program was not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.",
            code: .checkFailed)
    }

    /// Runs `claude` with `arguments`. A launch failure or a missing binary throws `check_failed`.
    /// A timeout is reported in the output, with the child ended.
    public func run(
        arguments: [String],
        configDir: URL? = nil,
        timeout: TimeInterval = 60,
        outputCap: Int = 1_048_576,
        passProxyEnv: Bool = false,
        workingDirectory: URL? = nil,
        environment: LaunchEnvironment = .probe
    ) throws -> RunOutput {
        try execute(
            arguments: arguments, configDir: configDir, timeout: timeout, outputCap: outputCap,
            passProxyEnv: passProxyEnv, workingDirectory: workingDirectory,
            environment: environment, inheritInput: false, rawOutput: nil)
    }

    /// Runs `claude setup-token` in the person's own environment with the terminal's input, and
    /// hands the child's raw output, standard output then standard error, to `rawOutput` once,
    /// before any scrubbing. Only the `Tokens` module calls it, so the one unscrubbed
    /// buffer stays there. What comes back has both scrub passes applied.
    func runSetupToken(timeout: TimeInterval, rawOutput: @escaping (Data) -> Void) throws
        -> RunOutput
    {
        try execute(
            arguments: ["setup-token"], configDir: nil, timeout: timeout, outputCap: 1_048_576,
            passProxyEnv: false, workingDirectory: nil, environment: .person, inheritInput: true,
            rawOutput: rawOutput)
    }

    private func execute(
        arguments: [String], configDir: URL?, timeout: TimeInterval, outputCap: Int,
        passProxyEnv: Bool, workingDirectory: URL?, environment: LaunchEnvironment,
        inheritInput: Bool, rawOutput: ((Data) -> Void)?
    ) throws -> RunOutput {
        let exe = try locate()
        let env: [String: String]
        switch environment {
        case .probe:
            env = ChildEnvironment.probe(
                context: context, claudeFolder: exe.deletingLastPathComponent(),
                configDir: configDir, passProxyEnv: passProxyEnv)
        case .person:
            env = ChildEnvironment.person(context: context, configDir: configDir)
        }

        let proc = Process()
        proc.executableURL = exe
        proc.arguments = arguments
        proc.environment = env
        proc.currentDirectoryURL = workingDirectory ?? context.home
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        if !inheritInput { proc.standardInput = inPipe }

        let outCapture = Capture(cap: outputCap)
        let errCapture = Capture(cap: outputCap)
        let drained = DispatchGroup()
        func drain(_ pipe: Pipe, into capture: Capture) {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    drained.leave()
                } else {
                    capture.append(chunk)
                }
            }
        }
        drain(outPipe, into: outCapture)
        drain(errPipe, into: errCapture)

        let finished = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in finished.signal() }
        do {
            try proc.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw ToolError("Could not start claude.", code: .checkFailed)
        }
        if !inheritInput { try? inPipe.fileHandleForWriting.close() }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            proc.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        if drained.wait(timeout: .now() + 2) == .timedOut {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }

        let (outData, outOver) = outCapture.snapshot()
        let (errData, errOver) = errCapture.snapshot()
        rawOutput?(outData + errData)
        return RunOutput(
            status: timedOut ? -1 : proc.terminationStatus,
            stdout: Scrubber.tokenPass(outData),
            stderr: Scrubber.scrubText(String(decoding: errData, as: UTF8.self)),
            timedOut: timedOut,
            truncated: outOver || errOver)
    }
}

/// The probe command line of docs/ARCHITECTURE.md section 6.2. The probe itself ships in a later
/// slice; the form is fixed here so the safe-mode rule lives in one place.
public enum ProbeForm {
    public static func arguments(
        model: String = "haiku", budgetUsd: String = "0.05", safeMode: Bool
    )
        -> [String]
    {
        var args = [
            "-p", "Reply with the single word OK.", "--model", model, "--tools", "",
            "--disallowedTools", "mcp__*", "--strict-mcp-config", "--max-turns", "1",
            "--no-session-persistence", "--max-budget-usd", budgetUsd, "--output-format",
            "stream-json", "--verbose",
        ]
        if safeMode { args.append("--safe-mode") }
        return args
    }

    /// A probe that exits with an unknown-option complaint is `check_failed` with scrubbed text;
    /// the probe never falls back to normal mode silently.
    public static func failure(for output: RunOutput) -> Issue? {
        if output.timedOut {
            return Issue(.checkFailed, .error, "Check failed: probe timed out.")
        }
        let text = output.stderr.lowercased()
        if output.status != 0
            && (text.contains("unknown option") || text.contains("unknown argument"))
        {
            let shown = String(output.stderr.prefix(200)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            return Issue(.checkFailed, .error, "Check failed: \(shown)")
        }
        return nil
    }
}
