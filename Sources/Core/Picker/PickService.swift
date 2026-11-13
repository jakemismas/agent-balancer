import Foundation

public struct PickRequest: Sendable {
    public var model: String?
    public var settings: String?
    public var fullLogin: Bool
    public var caller: PickCaller
    public var exclude: [String]
    public var dryRun: Bool

    public init(
        model: String? = nil, settings: String? = nil, fullLogin: Bool = false,
        caller: PickCaller = .typed, exclude: [String] = [], dryRun: Bool = false
    ) {
        self.model = model
        self.settings = settings
        self.fullLogin = fullLogin
        self.caller = caller
        self.exclude = exclude
        self.dryRun = dryRun
    }
}

/// `pick`: refreshes stale readings, then under the pick lock decides, writes the launch file and
/// the lease, and logs one line (docs/ARCHITECTURE.md sections 4A and 7.2). A thrown `ToolError`
/// is exit 1 and nothing was written for it.
public struct PickService: Sendable {
    public let context: ToolContext
    public var clock: @Sendable () -> Date = { Date() }
    /// Seconds to wait for the pick lock.
    public var lockWaitSeconds: TimeInterval = 30

    public init(context: ToolContext) {
        self.context = context
    }

    public func pick(_ request: PickRequest) throws -> PickResult {
        let config = try ConfigStore(context: context).loadRequired()
        if let name = request.model, !PickModel.isValidName(name) {
            throw ToolError("--model is not a valid model name.")
        }
        for label in request.exclude where !ConfigValidator.isValidLabel(label) {
            throw ToolError("--exclude needs a valid account label.")
        }
        let caller = try CallerSettings.validate(request.settings, launch: config.launch)
        let model = PickModel.parse(request.model)
        let started = clock()
        let inherited = AmbientState(context.ambient)
        // Only a typed line is prefix-less for a login or token account, so only it needs proof
        // that the caller's own folder is the default one (DECISIONS D-83).
        let prefixlessReason =
            request.caller == .typed ? SessionFolder.prefixlessReason(context: context) : nil
        let ambientKey = inherited.key

        // Settings of the default folder: hook record, and key names (never values).
        let state = settingsState()
        let settingsIssue = state.issue
        let carriesKey = state.carriesKey
        let settingsKind = state.kind
        var observations = StatusObservations()
        observations.settings = SettingsObservation(issue: settingsKind, carriesKey: carriesKey)

        // Skips settled before any probe.
        var skips: [String: String] = [:]
        let runner = ClaudeRunner(context: context)
        for account in config.accounts {
            if let skip = preSkip(
                account, request: request, prefixlessReason: prefixlessReason,
                settingsIssue: settingsIssue, carriesKey: carriesKey, runner: runner,
                observations: &observations)
            {
                skips[account.label] = skip.reason
            }
        }

        // Refresh every account still in the running, at the same time, under one deadline.
        let store = ReadingStore(context: context)
        let live = config.accounts.filter { skips[$0.label] == nil }
        var forced = Set<String>()
        for account in live {
            if let r = try? store.load(label: account.label), Self.windowReset(r, now: started) {
                forced.insert(account.label)
            }
        }
        let elapsed = clock().timeIntervalSince(started)
        let remaining = max(1, Double(config.picker.deadlineSeconds) - elapsed)
        var refresher = Refresher(context: context, config: config, store: store)
        refresher.clock = clock
        let results = refresher.refresh(
            accounts: live, force: false, forced: forced,
            fable: model == .fable ? .forPick : .none, deadline: remaining)
        observations.add(results)
        for result in results {
            if case .failed(let issue) = result.status {
                switch issue.code {
                case .loginRejected: skips[result.label] = "login rejected"
                case .tokenMissing: skips[result.label] = "no token saved"
                default: break
                }
            }
        }

        // The decision, the launch file and the lease happen under the pick lock.
        let writer = NoFollowWriter(root: context.dataRoot)
        guard
            let lock = try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: lockWaitSeconds)
        else { throw ToolError("pick busy") }
        defer { lock.release() }

        let now = clock()
        let leaseStore = LeaseStore(context: context)
        var leases = try leaseStore.current(now: now, leaseMinutes: config.picker.leaseMinutes)
        Upkeep.run(
            context: context, snapshot: SessionsReader.read(context: context), openLeases: leases,
            leaseMinutes: config.picker.leaseMinutes, keepDays: config.launch.keepDays, now: now)

        var decision: PickDecision
        var leaseId: String?
        var path: URL?
        var typedArgs: String?
        var typedPrefix = ""
        while true {
            let inputs = config.accounts.map {
                PickInput(
                    account: $0, reading: try? store.load(label: $0.label), skip: skips[$0.label])
            }
            decision = Picker.decide(
                inputs: inputs, config: config, model: model,
                openLeases: LeaseStore.counts(leases), now: now)
            guard let index = decision.chosen else { break }
            let account = inputs[index].account
            if request.dryRun { break }
            let id = freshLeaseId(leases)
            // Render the typed recipe before any file exists, so a refusal leaves nothing behind.
            if request.caller == .typed {
                typedArgs = try Recipe.launchArgs(
                    settingsPath: LaunchFiles.fileURL(
                        context: context, label: account.label, leaseId: id
                    ).path)
                if account.kind == Kind.folder {
                    typedPrefix = try Recipe.launchPrefix(
                        configDir: FolderPaths.configDir(context: context, label: account.label)
                            .path)
                }
            }
            do {
                path = try LaunchFiles.create(
                    context: context, account: account, leaseId: id, caller: caller)
            } catch let error as ToolError where error.code == .tokenMissing {
                skips[account.label] = "no token saved"
                continue
            }
            leaseId = id
            do {
                leases.append(
                    Lease(id: id, label: account.label, model: request.model ?? "default", at: now))
                try leaseStore.save(leases)
            } catch {
                LaunchFiles.discard(context: context, label: account.label, leaseId: id)
                throw error
            }
            break
        }

        let label = decision.chosen.map { config.accounts[$0].label }
        var result = PickResult(
            pickedAt: now, model: request.model ?? "default", label: label, env: nil, args: nil,
            launchPrefix: nil, launchArgs: nil, unsetEnv: nil, backgroundOnly: false,
            reason: decision.reason, candidates: decision.candidates, dryRun: request.dryRun)
        if request.dryRun, label != nil {
            result.backgroundOnly = request.caller == .typed && ambientKey
        } else if label != nil, let path {
            let settingsPath = path.path
            var env: [String: String] = [:]
            if let label, config.account(label)?.kind == Kind.folder,
                let dir = try? FolderPaths.configDir(context: context, label: label)
            {
                env[ProtectedEnv.configDirVariable] = dir.path
            }
            result.env = env
            result.args = ["--settings", settingsPath]
            switch request.caller {
            case .typed:
                result.launchPrefix = typedPrefix
                result.launchArgs = typedArgs
                result.backgroundOnly = ambientKey
            case .launcher:
                result.unsetEnv = Recipe.unsetNames(env: env)
            }
        }
        if !request.dryRun {
            logPick(
                time: result.pickedAt, model: result.model, label: result.label,
                leaseId: leaseId, reason: result.reason, writer: writer)
        }
        lock.release()
        StatusBuilder.rebuildQuietly(context: context, observations: observations)
        return result
    }

    // MARK: Pieces

    /// What the caller's environment already holds: a config folder, or a token or key. One
    /// predicate for `pick` and for a typed `run --print-command`.
    struct AmbientState {
        var configDir: Bool
        var key: Bool

        init(_ ambient: [String: String]) {
            configDir = ambient[ProtectedEnv.configDirVariable] != nil
            key = ([ProtectedEnv.tokenVariable] + ProtectedEnv.keyNames)
                .contains { ambient[$0] != nil }
        }
    }

    /// What the default folder's settings file shows: the hook record state and key names.
    func settingsState() -> (issue: String?, kind: String?, carriesKey: Bool) {
        HookRecord(context: context).currentState()
    }

    /// Why an account is left out, and the state code when one applies.
    struct Skip {
        var reason: String
        var code: StateCode?
        init(_ reason: String, code: StateCode? = nil) {
            self.reason = reason
            self.code = code
        }
    }

    /// A reason to leave an account out before any probe, or nil.
    func preSkip(
        _ account: Account, request: PickRequest, prefixlessReason: String?, settingsIssue: String?,
        carriesKey: Bool, runner: ClaudeRunner, observations: inout StatusObservations
    ) -> Skip? {
        if request.exclude.contains(account.label) { return Skip("excluded by caller") }
        if let ends = Picker.endsAtEnd(account.endsAt), clock() >= ends {
            return Skip("account ended")
        }
        guard Kind.all.contains(account.kind) else {
            return Skip("this account kind is not available in this version")
        }
        if request.fullLogin && account.kind == Kind.token {
            return Skip("token sessions have no connectors")
        }
        // A folder account's recipe carries its own literal prefix, which beats whatever the
        // caller's environment holds. A login or token recipe has no prefix.
        if let prefixlessReason, account.kind != Kind.folder { return Skip(prefixlessReason) }
        if account.kind == Kind.folder {
            let outcome = Verifier.failures(
                context: context, account: account, runner: runner, settingsIssue: settingsIssue,
                now: clock(), stopAtFirst: true)
            if let check = outcome.check {
                observations.auth[account.label] = AuthObservation(check)
            }
            if let failure = outcome.failures.first {
                return Skip(failure.reason, code: failure.code)
            }
            return nil
        }
        if let settingsIssue { return Skip(settingsIssue, code: .settingsChanged) }
        if account.kind == Kind.token {
            if carriesKey {
                return Skip("settings carry an API key or key helper", code: .keyInSettings)
            }
            // A file that does not parse counts as no token, so it is never probed or offered.
            guard TokenStore.isUsable(context: context, label: account.label) else {
                return Skip("no token saved", code: .tokenMissing)
            }
        }
        if account.kind == Kind.login, let handler = AccountKinds.handler(for: Kind.login) {
            let check = handler.check(account: account, runner: runner, now: clock())
            observations.auth[account.label] = AuthObservation(check)
            if let issue = check.issues.first(where: { $0.severity == .error }) {
                return Skip(Display.safe(issue.text, limit: 200), code: issue.code)
            }
        }
        return nil
    }

    /// True when a stored window's reset time has passed, so its use is no longer current.
    static func windowReset(_ reading: Reading, now: Date) -> Bool {
        [WindowName.fiveHour, WindowName.sevenDay].contains { name in
            (reading.windows[name]?.resetsAt).map { $0 <= now } ?? false
        }
    }

    func freshLeaseId(_ leases: [Lease]) -> String {
        while true {
            let id = LaunchFiles.makeLeaseId()
            if !leases.contains(where: { $0.id == id }) { return id }
        }
    }

    /// One line per pick: time, model, label or none, lease id, reason. Nothing personal.
    func logPick(
        time: Date, model: String, label: String?, leaseId: String?, reason: String,
        writer: NoFollowWriter
    ) {
        let line =
            [
                ISO8601DateFormatter().string(from: time), model, label ?? "none", leaseId ?? "-",
                Display.safe(reason, limit: 300),
            ].joined(separator: " ") + "\n"
        try? writer.append(Data(line.utf8), folders: Layout.stateFolders, name: Layout.picksLogName)
    }
}
