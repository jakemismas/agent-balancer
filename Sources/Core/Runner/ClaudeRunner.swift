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
    /// tests only for `~/.local/bin`, and the folder that holds the real target gets them unless
    /// it is one of Homebrew's bin folders.
    public func locate() throws -> URL {
        guard let found = try firstTrusted() else {
            throw ToolError(
                "The claude program was not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.",
                code: .checkFailed)
        }
        return found
    }

    /// Throws the refusal `locate` gives the binary it finds, so a command that only hands out a
    /// line that starts `claude`, as `pick` does, refuses what every command that starts it
    /// refuses. When no binary is found it throws nothing, since no binary is refused.
    public func checkFound() throws {
        _ = try firstTrusted()
    }

    /// The first candidate that exists and passes the tests, nil when none exists; the first one
    /// that exists and fails throws its refusal.
    private func firstTrusted() throws -> URL? {
        let localBin = context.home.appendingPathComponent(".local/bin").standardizedFileURL.path
        for candidate in candidates {
            let shown = context.display(candidate)
            let folder = candidate.deletingLastPathComponent()
            let inLocalBin = folder.standardizedFileURL.path == localBin
            // A folder that cannot be checked also keeps what it holds from being checked.
            let found = try lookUpProgram(candidate, shown: shown) {
                if inLocalBin { try checkLocalBin(folder, shown: shown) }
            }
            guard let facts = found else { continue }
            if inLocalBin { try checkLocalBin(folder, shown: shown) }
            try checkTargetFolder(facts, shown: shown)
            return candidate
        }
        return nil
    }

    /// What a look at the program at `candidate`, shown as `shown`, finds: nil when nothing that
    /// can run is there, else the facts of its real target once it passes the test of a binary:
    /// owned by the user or root, not writable by group or others, executable, with no access
    /// list that lets another user or group change it or that cannot be read. A lookup that stops
    /// is refused, after `first`. The menu app's lookup of the command line tool runs it too.
    func lookUpProgram(_ candidate: URL, shown: String, first: () throws -> Void = {}) throws
        -> FileFacts?
    {
        switch FileFacts.look(candidate) {
        case .missing:
            return nil
        case .unchecked(let stop):
            try first()
            throw ToolError(uncheckedText(shown, stop, ofFolder: false), code: .checkFailed)
        case .found(let facts):
            guard facts.isRegularFile else { return nil }
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
            return facts
        }
    }

    /// Refuses the binary found at `shown`, whose real target `target` describes, when the folder
    /// that holds that file is not owned by the user or root, is writable by group or others, or
    /// has an access list that lets another user or group change it or that cannot be read or
    /// checked: whoever can change that folder can put another program in the real target's
    /// place. A real target that sits in one of Homebrew's bin folders leaves that folder unjudged.
    private func checkTargetFolder(_ target: FileFacts, shown: String) throws {
        let folder = (target.realPath as NSString).deletingLastPathComponent
        guard !homebrewFolders.contains(folder) else { return }
        let what = "its real target's folder `\(typed(folder))`"
        switch FileFacts.look(URL(fileURLWithPath: folder)) {
        case .missing:
            throw ToolError(
                uncheckedText(shown, .unknown(path: folder), what: what), code: .checkFailed)
        case .unchecked(let stop):
            throw ToolError(uncheckedText(shown, stop, what: what), code: .checkFailed)
        case .found(let facts):
            guard facts.ownerIsUserOrRoot, !facts.writableByOthers else {
                throw ToolError(
                    Messages.claudeTargetFolderRefused(
                        shown, typed(facts.realPath), fix: modeFix(facts)),
                    code: .checkFailed)
            }
            guard !facts.listLetsOthersChange else {
                throw ToolError(
                    Messages.claudeTargetFolderSharedByAccessList(
                        shown, typed(facts.realPath), fix: clearFix(facts)),
                    code: .checkFailed)
            }
        }
    }

    /// Homebrew's bin folders, the folders of the candidates other than `~/.local/bin`, as
    /// written and as their real paths. They are group-writable on a standard install, so
    /// judging them would refuse every Homebrew binary.
    private var homebrewFolders: Set<String> {
        let localBin = context.home.appendingPathComponent(".local/bin").standardizedFileURL.path
        var folders = Set<String>()
        for candidate in candidates {
            let folder = candidate.deletingLastPathComponent().standardizedFileURL.path
            guard folder != localBin else { continue }
            folders.insert(folder)
            if let resolved = realpath(folder, nil) {
                folders.insert(String(cString: resolved))
                free(resolved)
            }
        }
        return folders
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
    /// pass. A system flag gets no command, since only an administrator can clear it. A file is
    /// never taken for the home folder, since its identity says it is not a folder.
    func clearFix(_ facts: FileFacts) -> String {
        guard let flags = facts.flags else {
            return clearSentence(
                facts.realPath, facts.identity, ownerIsUser: facts.ownerIsUser, unlocking: [])
        }
        guard !flags.system else {
            return
                "A system flag keeps that list from being cleared, and only an administrator can clear that flag."
        }
        return clearSentence(
            facts.realPath, facts.identity, ownerIsUser: facts.ownerIsUser, unlocking: flags.user)
    }

    /// The sentence that takes group and others' write off the folder `facts` describe:
    /// `chmod go-w` on its real path, with `sudo` first for a folder of root's, after the
    /// `chflags` that clears a user flag that locks it, which `chmod` cannot pass. One of root's
    /// whose sticky bit is on, such as `/tmp`, is shared on purpose, and another user's only that
    /// user or an administrator can change, so neither gets one. A system flag gets none either.
    func modeFix(_ facts: FileFacts) -> String? {
        guard facts.ownerIsUser || (facts.ownerIsUserOrRoot && !facts.isSticky) else {
            return nil
        }
        let owner = facts.ownerIsUser
        guard let flags = facts.flags else {
            return fixSentence("chmod go-w", facts.realPath, ownerIsUser: owner, unlocking: [])
        }
        guard !flags.system else {
            return
                "A system flag keeps that mode from being changed, and only an administrator can clear that flag."
        }
        return fixSentence("chmod go-w", facts.realPath, ownerIsUser: owner, unlocking: flags.user)
    }

    /// The sentence that names `chmod -N` on `path`, whose identity is `identity`, after the
    /// `chflags` that clears the user's flags `unlocking` when there are any, each with `sudo`
    /// first when root owns the entry, and says that it drops every entry of the list. An entry
    /// that may be the home folder gets what to check instead.
    func clearSentence(
        _ path: String, _ identity: FileFacts.Identity?, ownerIsUser: Bool, unlocking: [String]
    ) -> String {
        if mayBeHome(path, identity) { return homeCheck(path, identity) }
        return fixSentence(
            "chmod -N", path, ownerIsUser: ownerIsUser, unlocking: unlocking,
            closing: Self.dropsEveryEntry)
    }

    /// What every sentence that names a `chmod -N` says it does.
    static let dropsEveryEntry = " to drop every entry of its access list"

    /// What a refusal of the access list of `path`, which may be the home folder, says in place
    /// of a `chmod -N`.
    func homeCheck(_ path: String, _ identity: FileFacts.Identity?) -> String {
        "Check its access list with `ls -led \(typed(path))`: \(homeReason(path, identity))."
    }

    /// The same when the user cannot read the attributes of `path`, which reading its list needs
    /// too, so `chmod -a` there cannot read the list it takes one entry from: it fails, and on an
    /// entry the user owns it writes the list back empty.
    func unreadHomeCheck(_ path: String, _ identity: FileFacts.Identity?) -> String {
        let reason = homeReason(path, identity)
        return
            "Reading its list needs that right too, so `ls -led \(typed(path))` fails, and `chmod -a` cannot remove one entry: it fails, and empties the list when you own it. "
            + reason.prefix(1).uppercased() + reason.dropFirst() + "."
    }

    /// What a refusal of the link at `path`, which leads to the home folder or may, says in place
    /// of its `chmod -h -N`: a shell can make a command follow the link to the home folder.
    func homeLinkCheck(_ path: String, _ identity: FileFacts.Identity?) -> String {
        isHome(path, identity)
            ? "It leads to your home folder, so no command is named for it: one that follows the link acts on the home folder itself."
            : "Whether it leads to your home folder cannot be checked, so no command is named for it."
    }

    /// Why no `chmod -N` is named for `path`: clearing the home folder's whole list would also
    /// drop the entry macOS keeps there, and `path` is the home folder, or may be it when what it
    /// is or what the home is cannot be found.
    func homeReason(_ path: String, _ identity: FileFacts.Identity?) -> String {
        let drop = "clearing the whole list would also drop the entry macOS keeps on a home folder"
        guard isHome(path, identity) else {
            return "whether it is your home folder cannot be checked, and " + drop
        }
        return drop
    }

    /// The sentence that names `change`, a `chmod` with its operands but the path, on `path`,
    /// after the `chflags` that clears the user's flags `unlocking` when there are any, each with
    /// `sudo` first when root owns the entry, and ends with `closing`, which says what it does.
    func fixSentence(
        _ change: String, _ path: String, ownerIsUser: Bool, unlocking: [String],
        closing: String = ""
    ) -> String {
        let command = (ownerIsUser ? "" : "sudo ") + change + " " + typed(path)
        guard !unlocking.isEmpty else { return "Run `\(command)` in Terminal\(closing)." }
        let names = unlocking.map { "no" + $0 }.joined(separator: ",")
        let unlock = (ownerIsUser ? "" : "sudo ") + "chflags \(names) \(typed(path))"
        return "Run `\(unlock)`, then `\(command)` in Terminal\(closing)."
    }

    /// What a refusal says when the lookup of the binary, or of its folder when `ofFolder` is
    /// true, stops at `stop`: where it stops, and the command that lets it through when one is
    /// known to, or why none does when that is known.
    func uncheckedText(_ shown: String, _ stop: FileFacts.Stop, ofFolder: Bool) -> String {
        uncheckedText(shown, stop, what: ofFolder ? "its folder" : "it")
    }

    /// The same for the lookup of what `what` names, such as the folder that holds the real
    /// target.
    func uncheckedText(_ shown: String, _ stop: FileFacts.Stop, what: String) -> String {
        let because: String?
        var fix: String?
        switch stop {
        case .unsearchable(let path, let clearer, let unlocking, let holder, let identity):
            because = "you cannot search the folder `\(typed(path))`"
            if let clearer {
                fix = clearSentence(
                    path, identity, ownerIsUser: clearer == .user, unlocking: unlocking)
            } else {
                fix = holder.map(heldText)
            }
        case .closedByMode(let path, let unlocking):
            because = "you cannot search the folder `\(typed(path))`"
            fix = fixSentence("chmod u+x", path, ownerIsUser: true, unlocking: unlocking)
        case .unreadable(let path, let isLink, let clearer, let holder, let identity):
            because =
                !isLink
                ? "you cannot read the attributes of `\(typed(path))`"
                : clearer == nil
                    ? "you cannot read the link `\(typed(path))`"
                    : "you cannot read the attributes of the link `\(typed(path))`"
            guard let clearer else {
                fix =
                    isLink
                    ? "No chmod can clear the access list of a link you cannot read."
                    : holder.map(heldText)
                break
            }
            // A link that leads to the home gets none: a shell can make a command follow it.
            if mayBeHome(path, identity) {
                fix = isLink ? homeLinkCheck(path, identity) : unreadHomeCheck(path, identity)
            } else if clearer == .unreadOwner {
                // Its owner cannot be read, so the user's own command is named for when it is.
                fix =
                    "If you own it, run `chmod \(isLink ? "-h " : "")-N \(typed(path))` in Terminal\(Self.dropsEveryEntry)."
            } else {
                fix = clearSentence(
                    path, identity, ownerIsUser: clearer == .user, unlocking: [])
            }
        case .policy(let path):
            because =
                "a system policy, such as a sandbox profile, keeps you from `\(typed(path))`, and no chmod clears that"
            fix = nil
        case .unknown:
            because = nil
        }
        return Messages.claudeUnchecked(shown, what: what, because: because, fix: fix)
    }

    /// Why no command of the user's lets a lookup through, for what `holder` says keeps it.
    func heldText(_ holder: FileFacts.Holder) -> String {
        switch holder {
        case .owner:
            return "Only its owner or an administrator can change it."
        case .systemFlag:
            return
                "A system flag on it may keep it from being changed, and only an administrator can clear that flag."
        case .unreadLock:
            return
                "A flag on it may keep its list from being changed, and the chflags command cannot read it to clear that flag."
        }
    }

    /// The `chmod -N` that clears the access list at `path`, as a person types it, with `sudo`
    /// first when root owns the entry.
    func clearCommand(_ path: String, ownerIsUser: Bool) -> String {
        (ownerIsUser ? "" : "sudo ") + "chmod -N " + typed(path)
    }

    /// The home folder's path as written, as Foundation standardizes it and as its real path,
    /// which `FileFacts.resolve` finds without reading the home's own attributes, so a path
    /// through any of them is typed after `~`.
    var homes: [String] {
        let written = [context.home.path, context.home.standardizedFileURL.path]
        guard let real = FileFacts.resolve(context.home.path) else { return written }
        return written + [real]
    }

    /// What the home folder is, from an events-only open of it as written that follows its
    /// links, or nil when that fails.
    var homeIdentity: FileFacts.Identity? {
        FileFacts.identity(context.home.path, options: O_DIRECTORY)
    }

    /// Whether the entry at `path`, whose identity is `identity`, is the home folder, or for a
    /// link, leads to it: by its device and inode, or by its spelling.
    func isHome(_ path: String, _ identity: FileFacts.Identity?) -> Bool {
        guard !homes.contains(path) else { return true }
        guard let identity, identity != .notAFolder else { return false }
        return identity == homeIdentity
    }

    /// Whether it may be: it is, or it may be a folder and what it is or what the home is cannot
    /// be found, so it cannot be told from the home. What is not a folder never is.
    func mayBeHome(_ path: String, _ identity: FileFacts.Identity?) -> Bool {
        guard identity != .notAFolder else { return homes.contains(path) }
        guard let identity, let home = homeIdentity else { return true }
        return identity == home || homes.contains(path)
    }

    /// `path` as a person types it: the home folder as `~` and a path in it after `~/`, through
    /// its links or not, the rest quoted for a shell.
    func typed(_ path: String) -> String {
        let homes = homes
        if homes.contains(path) { return "~" }
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
