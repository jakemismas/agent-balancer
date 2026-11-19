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
    /// target. A candidate whose real target is not owned by the user or root, is writable by
    /// group or others, has an access list that lets another user or group change it or that
    /// cannot be read, or cannot be checked at all, is refused. The parent folder gets the same
    /// tests only for `~/.local/bin`.
    public func locate() throws -> URL {
        let localBin = context.home.appendingPathComponent(".local/bin").standardizedFileURL.path
        for candidate in candidates {
            let shown = context.display(candidate)
            let folder = candidate.deletingLastPathComponent()
            let inLocalBin = folder.standardizedFileURL.path == localBin
            let facts: FileFacts
            switch FileFacts.look(candidate) {
            case .missing:
                continue
            case .unchecked(let stop):
                // A folder that cannot be checked also keeps what it holds from being checked.
                if inLocalBin { try checkLocalBin(folder, shown: shown) }
                throw ToolError(uncheckedText(shown, stop, ofFolder: false), code: .checkFailed)
            case .found(let found):
                guard found.isRegularFile else { continue }
                facts = found
            }
            guard facts.ownerIsUserOrRoot, !facts.writableByOthers, facts.isExecutable else {
                throw ToolError(
                    "Refused \(shown): it must be an executable owned by you or root and not writable by others.",
                    code: .checkFailed)
            }
            guard !facts.listLetsOthersChange else {
                throw ToolError(
                    Messages.claudeSharedByAccessList(shown, fix: clearFix(facts)),
                    code: .checkFailed)
            }
            if inLocalBin { try checkLocalBin(folder, shown: shown) }
            return candidate
        }
        throw ToolError(
            "The claude program was not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.",
            code: .checkFailed)
    }

    /// Refuses `~/.local/bin`, which holds the binary found at `shown`, when its real folder is
    /// not owned by the user or root, is writable by group or others, or has an access list that
    /// lets another user or group change it or that cannot be read or checked.
    private func checkLocalBin(_ folder: URL, shown: String) throws {
        let modeRefusal = ToolError(
            "Refused \(shown): its folder must be owned by you or root and not writable by others.",
            code: .checkFailed)
        switch FileFacts.look(folder) {
        case .missing:
            throw modeRefusal
        case .unchecked(let stop):
            throw ToolError(uncheckedText(shown, stop, ofFolder: true), code: .checkFailed)
        case .found(let facts):
            guard facts.ownerIsUserOrRoot, !facts.writableByOthers else { throw modeRefusal }
            guard !facts.listLetsOthersChange else {
                throw ToolError(
                    Messages.claudeFolderSharedByAccessList(shown, fix: clearFix(facts)),
                    code: .checkFailed)
            }
        }
    }

    /// The sentence that clears the access list of what `facts` describe: `chmod -N` on its real
    /// path, after the `chflags` that clears a user flag that locks it, which `chmod -N` cannot
    /// pass. A system flag gets no command, since only an administrator can clear it.
    func clearFix(_ facts: FileFacts) -> String {
        guard let flags = facts.flags else {
            return clearSentence(facts.realPath, ownerIsUser: facts.ownerIsUser, unlocking: [])
        }
        guard !flags.system else {
            return
                "A system flag keeps that list from being cleared, and only an administrator can clear that flag."
        }
        return clearSentence(facts.realPath, ownerIsUser: facts.ownerIsUser, unlocking: flags.user)
    }

    /// The sentence that names `chmod -N` on `path`, after the `chflags` that clears the user's
    /// flags `unlocking` when there are any, each with `sudo` first when root owns the entry.
    func clearSentence(_ path: String, ownerIsUser: Bool, unlocking: [String]) -> String {
        let clear = clearCommand(path, ownerIsUser: ownerIsUser)
        guard !unlocking.isEmpty else { return "Run `\(clear)` in Terminal." }
        let names = unlocking.map { "no" + $0 }.joined(separator: ",")
        let unlock = (ownerIsUser ? "" : "sudo ") + "chflags \(names) \(typed(path))"
        return "Run `\(unlock)`, then `\(clear)` in Terminal."
    }

    /// What a refusal says when the lookup of the binary, or of its folder when `ofFolder` is
    /// true, stops at `stop`: where it stops, and the `chmod -N` that lets it through, after the
    /// `chflags` that clears a lock, only when that is known to.
    func uncheckedText(_ shown: String, _ stop: FileFacts.Stop, ofFolder: Bool) -> String {
        let because: String?
        var fix: String?
        switch stop {
        case .unsearchable(let path, let clearer, let unlocking):
            because = "you cannot search the folder `\(typed(path))`"
            if let clearer {
                fix = clearSentence(path, ownerIsUser: clearer == .user, unlocking: unlocking)
            }
        case .unreadable(let path, let isLink, let clearer):
            because =
                isLink
                ? "you cannot read the link `\(typed(path))`"
                : "you cannot read the attributes of `\(typed(path))`"
            if let clearer {
                fix = clearSentence(path, ownerIsUser: clearer == .user, unlocking: [])
            }
        case .unknown:
            because = nil
        }
        return Messages.claudeUnchecked(shown, ofFolder: ofFolder, because: because, fix: fix)
    }

    /// The `chmod -N` that clears the access list at `path`, as a person types it, with `sudo`
    /// first when root owns the entry.
    func clearCommand(_ path: String, ownerIsUser: Bool) -> String {
        (ownerIsUser ? "" : "sudo ") + "chmod -N " + typed(path)
    }

    /// `path` as a person types it: a path in the home folder, through its links or not, after
    /// `~/`, the rest quoted for a shell.
    func typed(_ path: String) -> String {
        var homes = [context.home.standardizedFileURL.path]
        if let resolved = realpath(context.home.path, nil) {
            homes.append(String(cString: resolved))
            free(resolved)
        }
        guard let home = homes.first(where: { path.hasPrefix($0 + "/") }) else {
            return PickService.shellQuote(path)
        }
        return "~/" + PickService.shellQuote(String(path.dropFirst(home.count + 1)))
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

    /// Starts `claude` for a person with the terminal attached: standard input, output and error
    /// are the caller's own, the environment is the person's minus the protected group, and the
    /// arguments are passed as an array. Returns the child's exit status, or 128 plus the signal
    /// number when a signal ended it. A folder account's folder goes in as `CLAUDE_CONFIG_DIR`.
    public func launchAttached(arguments: [String], configDir: URL? = nil) throws -> Int32 {
        let exe = try locate()
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = arguments
        proc.environment = ChildEnvironment.person(context: context, configDir: configDir)
        // Left unset, the three standard streams are the caller's own.
        do {
            try proc.run()
        } catch {
            throw ToolError("Could not start claude.", code: .checkFailed)
        }
        proc.waitUntilExit()
        if proc.terminationReason == .uncaughtSignal { return 128 + proc.terminationStatus }
        return proc.terminationStatus
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
        return try ChildProcess.run(
            executable: exe, program: "claude", arguments: arguments, environment: env,
            workingDirectory: workingDirectory ?? context.home, timeout: timeout,
            outputCap: outputCap, inheritInput: inheritInput, rawOutput: rawOutput)
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
