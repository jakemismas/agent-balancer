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
        let ambient = context.ambient
        let ambientConfigDir = ambient[ProtectedEnv.configDirVariable] != nil
        let ambientKey = ([ProtectedEnv.tokenVariable] + ProtectedEnv.keyNames)
            .contains { ambient[$0] != nil }

        // Settings of the default folder: hook record, and key names (never values).
        let hooks = HookRecord(context: context)
        var settingsIssue: String?
        var settingsKind: String?
        var carriesKey = false
        do {
            let facts = try hooks.readSettings()
            carriesKey = facts.carriesKey
            switch hooks.status(current: facts) {
            case .missing:
                settingsIssue = Messages.hookRecordMissing
                settingsKind = "missing"
            case .changed:
                settingsIssue = Messages.settingsChanged
                settingsKind = "changed"
            case .matches: break
            }
        } catch {
            settingsIssue = "settings.json could not be read or parsed."
            settingsKind = "changed"
        }
        var observations = StatusObservations()
        observations.settings = SettingsObservation(issue: settingsKind, carriesKey: carriesKey)

        // Skips settled before any probe.
        var skips: [String: String] = [:]
        let runner = ClaudeRunner(context: context)
        for account in config.accounts {
            if let reason = preSkip(
                account, request: request, ambientConfigDir: ambientConfigDir,
                settingsIssue: settingsIssue, carriesKey: carriesKey, runner: runner,
                observations: &observations)
            {
                skips[account.label] = reason
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
            result.env = [:]
            result.args = ["--settings", settingsPath]
            switch request.caller {
            case .typed:
                result.launchPrefix = ""
                result.launchArgs = typedArgs
                result.backgroundOnly = ambientKey
            case .launcher:
                result.unsetEnv = Recipe.unsetNames
            }
        }
        if !request.dryRun { logPick(result, leaseId: leaseId, writer: writer) }
        lock.release()
        StatusBuilder.rebuildQuietly(context: context, observations: observations)
        return result
    }

    // MARK: Pieces

    /// A reason to leave an account out before any probe, or nil.
    private func preSkip(
        _ account: Account, request: PickRequest, ambientConfigDir: Bool, settingsIssue: String?,
        carriesKey: Bool, runner: ClaudeRunner, observations: inout StatusObservations
    ) -> String? {
        if request.exclude.contains(account.label) { return "excluded by caller" }
        if let ends = Picker.endsAtEnd(account.endsAt), clock() >= ends { return "account ended" }
        guard account.kind == Kind.login || account.kind == Kind.token else {
            return "this account kind is not available in this version"
        }
        if request.fullLogin && account.kind == Kind.token {
            return "token sessions have no connectors"
        }
        if request.caller == .typed && ambientConfigDir { return "ambient CLAUDE_CONFIG_DIR set" }
        if let settingsIssue { return settingsIssue }
        if account.kind == Kind.token {
            if carriesKey { return "settings carry an API key or key helper" }
            // A file that does not parse counts as no token, so it is never probed or offered.
            guard TokenStore.isUsable(context: context, label: account.label) else {
                return "no token saved"
            }
        }
        if account.kind == Kind.login, let handler = AccountKinds.handler(for: Kind.login) {
            let check = handler.check(account: account, runner: runner, now: clock())
            observations.auth[account.label] = AuthObservation(check)
            if let issue = check.issues.first(where: { $0.severity == .error }) {
                return Display.safe(issue.text, limit: 200)
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

    private func freshLeaseId(_ leases: [Lease]) -> String {
        while true {
            let id = LaunchFiles.makeLeaseId()
            if !leases.contains(where: { $0.id == id }) { return id }
        }
    }

    /// One line per pick: time, model, label or none, lease id, reason. Nothing personal.
    private func logPick(_ result: PickResult, leaseId: String?, writer: NoFollowWriter) {
        let time = ISO8601DateFormatter().string(from: result.pickedAt)
        let line =
            [
                time, result.model, result.label ?? "none", leaseId ?? "-",
                Display.safe(result.reason, limit: 300),
            ].joined(separator: " ") + "\n"
        try? writer.append(Data(line.utf8), folders: Layout.stateFolders, name: Layout.picksLogName)
    }
}
