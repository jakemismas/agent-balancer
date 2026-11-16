import Foundation
import Testing

@testable import Core

/// The window's sign-in reading over the whole class: every account kind, every error code the
/// status writer records for it, and every code another can hide (each pair the ranking allows),
/// generated from the codes and the ranking and driven through the real writer.
extension ManageViewModelTests {
    /// One sign-in check of an account. `unreadable` is a check that read no status.
    enum GenCheck: String, CaseIterable, Sendable {
        case placed, planChanged, other, loggedOut, elsewhere, unreported, unreadable

        var readsStatus: Bool { self != .unreadable }
        /// The check saw an account signed in, so `login --browser` would refuse the folder.
        var sawSignIn: Bool {
            [.placed, .planChanged, .other, .elsewhere, .unreported].contains(self)
        }
        /// The check placed the expected sign-in in the account's own folder.
        var places: Bool { self == .placed || self == .planChanged }
        var folderOnly: Bool { self == .elsewhere || self == .unreported }

        /// What the writer records as the folder row's `signInCheck`.
        var seen: String? {
            switch self {
            case .placed, .planChanged: return "signed_in"
            case .other: return "other_account"
            case .loggedOut: return "signed_out"
            case .elsewhere, .unreported: return "not_confirmed"
            case .unreadable: return nil
            }
        }

        /// The error the check records.
        var code: String? {
            switch self {
            case .placed: return nil
            case .planChanged: return "plan_changed"
            case .other: return "wrong_account"
            case .loggedOut: return "login_rejected"
            case .elsewhere, .unreported, .unreadable: return "check_failed"
            }
        }
    }

    enum GenProbe: String, CaseIterable, Sendable {
        case none, ok, rejected, failed

        var code: String? {
            switch self {
            case .rejected: return "login_rejected"
            case .failed: return "check_failed"
            case .none, .ok: return nil
            }
        }

        var observation: ProbeObservation? {
            switch self {
            case .none: return nil
            case .ok: return ProbeObservation(error: nil)
            case .rejected:
                return ProbeObservation(error: Issue(.loginRejected, .error, "Rejected."))
            case .failed:
                return ProbeObservation(
                    error: Issue(.checkFailed, .error, "Check failed: timed out."))
            }
        }
    }

    enum GenLink: String, CaseIterable, Sendable { case ok, broken, notLinked }

    /// One generated row: what the account's checks, probes and setup were.
    struct GenCase: CustomStringConvertible, Sendable {
        var label: String
        var kind: String
        var checks: [GenCheck] = []
        /// The probe after the checks.
        var probe = GenProbe.none
        var link = GenLink.ok
        var tokenUsable = true
        var duplicate = false
        var ended = false
        var settingsChanged = false
        /// A probe before the first check, which a probe after the checks would replace.
        var probeBefore = GenProbe.none
        /// Marked ending soon, so a check that sees the plan drop ends the account.
        var endingSoon = false
        /// A stored reading at the limit.
        var limited = false

        var description: String {
            "\(label) \(kind) probe before \(probeBefore.rawValue) checks "
                + "\(checks.map(\.rawValue)) probe \(probe.rawValue) link \(link.rawValue) token "
                + "\(tokenUsable) duplicate \(duplicate) ended \(ended) ending soon \(endingSoon) "
                + "limited \(limited) settings changed \(settingsChanged)"
        }

        var lastSeen: GenCheck? { checks.last { $0.readsStatus } }

        /// The probe whose result the entry keeps: no check clears a probe's result.
        var lastProbe: GenProbe { probe != .none ? probe : probeBefore }

        /// A check placed the expected sign-in on a lower plan while the account ends soon.
        var endedByPlan: Bool { endingSoon && kind != Kind.token && checks.contains(.planChanged) }

        /// Every error code the writer records for the account, from the inputs alone.
        var recorded: Set<String> {
            var codes = Set<String>()
            // A probe that works after the checks clears a check's `login_rejected`, and an
            // account that ends soon shows no `plan_changed`.
            if let code = checks.last?.code, !(code == "login_rejected" && probe == .ok),
                !(code == "plan_changed" && endingSoon)
            {
                codes.insert(code)
            }
            if let code = lastProbe.code { codes.insert(code) }
            if kind == Kind.folder {
                switch link {
                case .ok: if settingsChanged { codes.insert("settings_changed") }
                case .broken: codes.insert("settings_changed")
                case .notLinked: codes.insert("not_linked")
                }
            } else if settingsChanged {
                codes.insert("settings_changed")
            }
            if kind == Kind.token, !tokenUsable { codes.insert("token_missing") }
            if duplicate { codes.insert("duplicate_login") }
            // A rejected sign-in shows over a plan drop; a date that passed shows over all.
            if ended || (endedByPlan && !codes.contains("login_rejected")) {
                codes.insert("account_ended")
            }
            return codes
        }

        /// The one code the row shows, by the ranking.
        var shown: String? {
            if ended { return "account_ended" }
            let first = Transitions.errorOrder.map(\.rawValue).first { recorded.contains($0) }
            if first != "login_rejected", recorded.contains("account_ended") {
                return "account_ended"
            }
            return first
        }

        /// The row's state: ended by its date or its plan, an error, limited by its reading, or
        /// ok.
        var state: String {
            if shown == "account_ended" { return "ended" }
            if shown != nil { return "error" }
            return limited ? "limited" : "ok"
        }

        /// The plan tier the row carries: only from a last check that placed the expected
        /// sign-in, with no doubt since.
        var tier: String? {
            guard kind != Kind.token, let last = checks.last, last.places,
                lastProbe != .rejected, lastProbe != .failed
            else { return nil }
            return last == .planChanged ? "pro" : "max_20x"
        }

        /// How the window must read the row, from what the checks saw.
        var expected: ManageBuilder.SignIn {
            switch kind {
            case Kind.folder:
                if lastSeen == .other { return .otherAccount }
                if lastSeen?.seen == "not_confirmed" { return .notConfirmed }
                if shown == "login_rejected" { return .signedOut }
                if link == .ok, tier != nil { return .signedIn }
                if link == .ok, lastSeen?.places == true { return .notConfirmed }
                return .notSignedIn
            case Kind.token:
                if ended { return .ended }
                if shown == "login_rejected" || shown == "token_missing" { return .signedOut }
                return shown == nil ? .signedIn : .notConfirmed
            default:
                if shown == "login_rejected" { return .signedOut }
                if shown == "wrong_account" { return .otherAccount }
                if state == "ended" { return .ended }
                // As a folder row does, a login row counts only by its tier, with no code or
                // under these two.
                if shown == nil || shown == "plan_changed" || shown == "duplicate_login" {
                    return tier != nil ? .signedIn : .notConfirmed
                }
                return .notConfirmed
            }
        }
    }

    static let pastDay = "2026-01-01"

    /// No check, each check alone, and each check that read a status followed by one that read
    /// none.
    static func checkRuns(folder: Bool) -> [[GenCheck]] {
        let checks = GenCheck.allCases.filter { folder || !$0.folderOnly }
        let readable = checks.filter { $0.readsStatus && $0 != .planChanged && $0 != .unreported }
        return [[]] + checks.map { [$0] } + readable.map { [$0, .unreadable] }
    }

    /// The probes around the checks: none, one after them, or one before the first check with
    /// none after, since a probe after would replace its result.
    static let probeRuns: [(before: GenProbe, after: GenProbe)] =
        GenProbe.allCases.map { (GenProbe.none, $0) }
        + [GenProbe.rejected, .failed].map { ($0, GenProbe.none) }

    /// The sign-in check `check` as the account's kind runs it.
    static func authObservation(_ check: GenCheck, account: Account, folder: URL?)
        -> AuthObservation
    {
        if check == .unreadable {
            return AuthObservation(
                AccountCheck(issues: [Issue(.checkFailed, .error, "Check failed: no answer.")]))
        }
        var dir = folder?.path
        if check == .elsewhere { dir = "/elsewhere/.claude" }
        if check == .unreported { dir = nil }
        let status = AuthStatus(
            loggedIn: check != .loggedOut,
            email: check == .other ? "other@example.com" : account.email,
            planTier: check == .loggedOut ? nil : (check == .planChanged ? "pro" : "max_20x"),
            configDirectory: dir)
        if let folder {
            return AuthObservation(
                FolderKind.evaluate(status, account: account, folder: folder, now: Date()))
        }
        return AuthObservation(LoginKind.evaluate(status, account: account, now: Date()))
    }

    /// One account of a generated home: a folder with a link state, or a token account with or
    /// without its token, each with or without a duplicate email and an end date that passed.
    struct GenSlot {
        var label: String
        var kind: String
        var link = GenLink.ok
        var tokenUsable = true
        var duplicate = false
        var ended = false
        var endingSoon = false
        var limited = false
    }

    static func genSlots() -> [GenSlot] {
        var slots: [GenSlot] = []
        for link in GenLink.allCases {
            for duplicate in [false, true] {
                for ended in [false, true] {
                    slots.append(
                        GenSlot(
                            label: "f\(slots.count)", kind: Kind.folder, link: link,
                            duplicate: duplicate, ended: ended))
                }
            }
            // An account keeps one end marker, so the one that ends soon has no date.
            slots.append(
                GenSlot(label: "f\(slots.count)", kind: Kind.folder, link: link, endingSoon: true))
            slots.append(
                GenSlot(label: "f\(slots.count)", kind: Kind.folder, link: link, limited: true))
        }
        for usable in [true, false] {
            for duplicate in [false, true] {
                for ended in [false, true] {
                    slots.append(
                        GenSlot(
                            label: "t\(slots.count)", kind: Kind.token, tokenUsable: usable,
                            duplicate: duplicate, ended: ended))
                }
            }
        }
        slots.append(GenSlot(label: "t\(slots.count)", kind: Kind.token, limited: true))
        return slots
    }

    /// The login account's ends: none, a stored reading at the limit, a date that passed, or
    /// ending soon.
    static let loginEnds: [(ended: Bool, endingSoon: Bool, limited: Bool)] = [
        (false, false, false), (false, false, true), (true, false, false), (false, true, false),
    ]

    static func loginCases() -> [GenCase] {
        var cases: [GenCase] = []
        for checks in checkRuns(folder: false) {
            for probes in probeRuns {
                for duplicate in [false, true] {
                    for end in loginEnds {
                        for settingsChanged in [false, true] {
                            cases.append(
                                GenCase(
                                    label: "main", kind: Kind.login, checks: checks,
                                    probe: probes.after, duplicate: duplicate, ended: end.ended,
                                    settingsChanged: settingsChanged, probeBefore: probes.before,
                                    endingSoon: end.endingSoon, limited: end.limited))
                        }
                    }
                }
            }
        }
        return cases
    }

    /// A reading at the limit, as a probe stores it.
    static func limitedReading(now: Date = Date()) -> Reading {
        let week = WindowReading(
            usedPercent: 100, resetsAt: now.addingTimeInterval(3 * 86_400), readAt: now)
        return Reading(readAt: now, windows: [WindowName.sevenDay: week])
    }

    /// The accounts of `cases` as a config: each gets a new account key, so the writer starts
    /// it fresh, and a duplicate gets a token account with the same email.
    static func genConfig(_ cases: [GenCase]) -> Config {
        var accounts: [Account] = []
        for c in cases {
            let email = c.kind == Kind.login ? "main@example.com" : "\(c.label)@example.com"
            accounts.append(
                Account(
                    label: c.label, kind: c.kind, role: Role.pool, email: email,
                    expectedPlanTier: c.kind == Kind.token ? nil : "max_20x",
                    endsAt: c.ended ? pastDay : nil, endingSoon: c.endingSoon ? true : nil))
            if c.duplicate {
                accounts.append(
                    Account(label: "d\(c.label)", kind: Kind.token, role: Role.pool, email: email))
            }
        }
        var config = Config(accounts: accounts)
        config.fable.probe = false
        return config
    }

    /// Writes `cases` through the real writer: a probe before the checks, the first sign-in
    /// check, then the second with the probe after it, as the commands that run them would.
    /// Returns each row and entry. It runs off the main actor, so the window tests around it are
    /// not held up.
    nonisolated static func writeGenerated(
        _ cases: [GenCase], settingsChanged: Bool, context: ToolContext
    )
        async
        throws -> (rows: [String: AccountStatus], entries: [String: CurrentEntry])
    {
        let config = genConfig(cases)
        try ConfigStore(context: context).save(config)
        let settings = SettingsObservation(
            issue: settingsChanged ? "changed" : nil, carriesKey: false)
        var before = StatusObservations(settings: settings)
        var first = StatusObservations(settings: settings)
        var second = StatusObservations()
        for c in cases {
            let account = try #require(config.account(c.label))
            let folder =
                c.kind == Kind.folder
                ? try FolderPaths.configDir(context: context, label: c.label) : nil
            before.probe[c.label] = c.probeBefore.observation
            if let check = c.checks.first {
                first.auth[c.label] = authObservation(check, account: account, folder: folder)
            }
            if c.checks.count > 1 {
                second.auth[c.label] = authObservation(
                    c.checks[1], account: account, folder: folder)
                second.probe[c.label] = c.probe.observation
            } else {
                first.probe[c.label] = c.probe.observation
            }
        }
        if !before.probe.isEmpty {
            _ = try StatusBuilder.rebuild(context: context, observations: before)
        }
        var document = try StatusBuilder.rebuild(context: context, observations: first)
        if !second.auth.isEmpty {
            document = try StatusBuilder.rebuild(context: context, observations: second)
        }
        let built = try #require(document)
        let data = try #require(
            try NoFollowReader(root: context.dataRoot).read(
                folders: Layout.stateFolders, name: "current.json"))
        return (
            Dictionary(uniqueKeysWithValues: built.accounts.map { ($0.label, $0) }),
            try EventLog.decoder().decode(CurrentFile.self, from: data).accounts
        )
    }

    /// Checks one generated row: what the writer wrote, how the window reads it, and the
    /// invariant, then returns the window's reading.
    @MainActor static func checkGenerated(
        _ c: GenCase, row: AccountStatus, entry: CurrentEntry?, vm: ManageViewModel
    ) throws {
        let name = "\(c)"
        // The writer recorded what the inputs say, and the row shows the ranking's first code.
        #expect(row.error?.code == c.shown, "\(name): code \(row.error?.code ?? "none")")
        #expect(row.state == c.state, "\(name): state \(row.state)")
        #expect(row.planTier == c.tier, "\(name): tier \(row.planTier ?? "none")")
        #expect(entry?.authError?.code == c.recordedAuth, "\(name): auth error")
        #expect(entry?.probeError?.code == c.lastProbe.code, "\(name): probe error")
        #expect(entry?.endedByPlan == c.endedByPlan, "\(name): ended by plan")
        if c.kind == Kind.folder {
            #expect(
                row.signInCheck == c.lastSeen?.seen, "\(name): check \(row.signInCheck ?? "none")")
        } else {
            #expect(row.signInCheck == nil, "\(name)")
        }

        let account = try #require(vm.accounts.first { $0.label == c.label })
        let state = ManageBuilder.signInState(account)
        #expect(state == c.expected, "\(name): reads \(state), expected \(c.expected)")
        let panel = ManageBuilder.panel(
            account, settings: vm.settings, now: Self.now, checked: nil, canAct: vm.canAct)
        let list = ManageBuilder.listRow(account, now: Self.now)
        #expect(
            panel.signedIn == list.signedIn && panel.signedIn == (state == .signedIn), "\(name)")
        var draft = AddDraft()
        draft.label = c.label
        draft.kind = c.kind
        draft.stage = .added
        let step = ManageBuilder.addSteps(
            draft, account: account, settings: vm.settings, canAct: vm.canAct, now: Self.now
        ).first { $0.id == 3 }

        // Never green unless the last check placed the expected sign-in (folders), or no code
        // could hide or contradict it (token), or a login row's tier stands with no code or
        // under a code that says nothing against it.
        if panel.signedIn {
            if c.kind == Kind.folder {
                #expect(
                    c.checks.last?.places == true && c.lastProbe != .rejected
                        && c.lastProbe != .failed && c.link == .ok,
                    "\(name): green without evidence")
            } else if c.kind == Kind.login {
                let tierUnder = ["plan_changed", "duplicate_login"].contains(row.error?.code)
                #expect(
                    row.planTier != nil && (row.error == nil || tierUnder),
                    "\(name): green without a tier")
            } else {
                #expect(row.error == nil, "\(name): green with a code")
            }
        }
        if c.kind == Kind.folder {
            // Never a Sign in that `login --browser` would refuse as already signed in: a
            // standing probe rejection lets it sign the folder in again.
            let offered = panel.signIn?.enabled == true || step?.actionEnabled == true
            let refused = c.lastSeen?.sawSignIn == true && c.lastProbe != .rejected
            #expect(!(offered && refused), "\(name): offers a Sign in that would be refused")
            if c.lastSeen == .other {
                #expect(panel.signInText == "Signed in as another account", "\(name)")
                #expect(panel.problem?.title == "Wrong account" && panel.signIn == nil, "\(name)")
                #expect(step?.state == .todo, "\(name)")
            }
        }
    }

    /// Error codes a row can carry, and the codes each kind can never record.
    static let warningOnlyCodes: Set<StateCode> = [
        .limited, .fableLimited, .loginExpiring, .possibleDuplicate, .keyInSettings, .stale,
        .launchFileMissing,
    ]
    static let neverRecorded: [String: Set<String>] = [
        Kind.folder: ["token_missing"],
        Kind.token: ["wrong_account", "plan_changed", "not_linked"],
        Kind.login: ["token_missing", "not_linked"],
    ]
    /// Pairs that cannot be on one row: one check records one error, a folder has one link
    /// verdict, and a token account's only check is its probe.
    static let neverTogether: [String: Set<[String]>] = [
        Kind.folder: [["settings_changed", "not_linked"], ["wrong_account", "plan_changed"]],
        Kind.token: [["login_rejected", "check_failed"]],
        Kind.login: [["wrong_account", "plan_changed"]],
    ]

    @Test @MainActor func everyKindCodeAndHiddenCodeReadsFailClosedThroughTheRealWriter()
        async throws
    {
        var all: [GenCase] = []
        let slots = Self.genSlots()

        // One home for every folder and token row: the link states, token files and folders are
        // made once, and each batch of checks writes its accounts afresh.
        let (t, context) = try FolderAccountsTests().setUp(
            folders: slots.filter { $0.kind == Kind.folder }.map(\.label))
        defer { withExtendedLifetime(t) {} }
        let setup = try ConfigStore(context: context).loadRequired()
        for slot in slots where slot.kind == Kind.folder && slot.link != .notLinked {
            let plan = try Linker.plan(
                context: context, config: setup, label: slot.label, repair: false)
            _ = try Linker.apply(context: context, plan: plan)
        }
        let hooks = HookRecord(context: context)
        try hooks.record(try hooks.readSettings())
        for slot in slots where slot.kind == Kind.folder && slot.link == .broken {
            try FileManager.default.removeItem(
                at: try FolderPaths.configDir(context: context, label: slot.label)
                    .appendingPathComponent("CLAUDE.md"))
        }
        for slot in slots where slot.kind == Kind.token && slot.tokenUsable {
            _ = try t.makeTokenFile(label: slot.label, secret: Canaries.oauth())
        }
        for slot in slots where slot.limited {
            try ReadingStore(context: context).save(Self.limitedReading(), label: slot.label)
        }
        let tool = try Self.loggingTool(in: t.home)
        let vm = ManageViewModel(
            context: context, runner: CLIRunner(context: context, candidates: [tool.exe]),
            clock: { Self.now })
        vm.windowOpened()
        for checks in Self.checkRuns(folder: true) {
            for probes in Self.probeRuns {
                for settingsChanged in [false, true] {
                    // A token account has no sign-in check, so its rows come with no check.
                    let cases = slots.filter { $0.kind == Kind.folder || checks.isEmpty }.map {
                        GenCase(
                            label: $0.label, kind: $0.kind,
                            checks: $0.kind == Kind.folder ? checks : [], probe: probes.after,
                            link: $0.link, tokenUsable: $0.tokenUsable, duplicate: $0.duplicate,
                            ended: $0.ended, settingsChanged: settingsChanged,
                            probeBefore: probes.before, endingSoon: $0.endingSoon,
                            limited: $0.limited)
                    }
                    let (rows, entries) = try await Self.writeGenerated(
                        cases, settingsChanged: settingsChanged, context: context)
                    vm.statusMayHaveChanged()
                    for c in cases {
                        let row = try #require(rows[c.label], "\(c)")
                        try Self.checkGenerated(c, row: row, entry: entries[c.label], vm: vm)
                    }
                    all += cases
                    await Task.yield()
                }
            }
        }

        // The login account, one at a time, since a setup has one: one home with a reading at
        // the limit and one without.
        var loginHomes: [Bool: (TestHome, ManageViewModel)] = [:]
        for limited in [false, true] {
            let home = try TestHome()
            if limited {
                try ReadingStore(context: home.context).save(Self.limitedReading(), label: "main")
            }
            let model = ManageViewModel(
                context: home.context,
                runner: CLIRunner(context: home.context, candidates: [tool.exe]),
                clock: { Self.now })
            model.windowOpened()
            loginHomes[limited] = (home, model)
        }
        for c in Self.loginCases() {
            let (home, loginVM) = try #require(loginHomes[c.limited])
            let (rows, entries) = try await Self.writeGenerated(
                [c], settingsChanged: c.settingsChanged, context: home.context)
            loginVM.statusMayHaveChanged()
            try Self.checkGenerated(
                c, row: try #require(rows[c.label]), entry: entries[c.label], vm: loginVM)
            all.append(c)
            await Task.yield()
        }

        // The table covers every code each kind can record, and every code another can hide.
        let order = Transitions.errorOrder.map(\.rawValue)
        func rank(_ code: String) -> Int {
            code == StateCode.accountEnded.rawValue
                ? -1 : (order.firstIndex(of: code) ?? order.count)
        }
        let errorCodes = StateCode.allCases.filter { !Self.warningOnlyCodes.contains($0) }
            .map(\.rawValue)
        for kind in [Kind.folder, Kind.token, Kind.login] {
            let cases = all.filter { $0.kind == kind }
            let codes = Set(errorCodes).subtracting(Self.neverRecorded[kind] ?? [])
            let recorded = cases.reduce(into: Set<String>()) { $0.formUnion($1.recorded) }
            #expect(recorded == codes, "\(kind) records \(recorded.sorted())")
            var pairs = Set<[String]>()
            for c in cases {
                guard let shown = c.shown else { continue }
                for hidden in c.recorded where hidden != shown { pairs.insert([shown, hidden]) }
            }
            let never = Self.neverTogether[kind] ?? []
            for over in codes {
                for under in codes where rank(over) < rank(under) {
                    if never.contains([over, under]) {
                        #expect(!pairs.contains([over, under]), "\(kind): \(over) over \(under)")
                    } else {
                        #expect(
                            pairs.contains([over, under]),
                            "\(kind): no row with \(over) over \(under)")
                    }
                }
            }
        }
        // A probe before the checks, a reading at the limit and a plan drop are each in it.
        #expect(all.contains { $0.probeBefore == .rejected && $0.checks == [.placed] })
        #expect(all.contains { $0.state == "limited" })
        #expect(all.contains { $0.endedByPlan && $0.state == "ended" })
        #expect(all.count == 3564)
        #expect(Self.lines(tool.log).isEmpty)
    }
}

extension ManageViewModelTests.GenCase {
    /// The sign-in check error the entry keeps: the last check's, unless a probe that worked
    /// cleared its `login_rejected`.
    var recordedAuth: String? {
        guard let code = checks.last?.code else { return nil }
        return code == "login_rejected" && probe == .ok ? nil : code
    }
}

/// Named cases of the same class, through the real writer.
extension ManageViewModelTests {
    /// A folder whose own folder holds another account, then a hook change, then an
    /// end date that passed, then the hook change accepted. It reads as another account
    /// throughout, never green, with no Sign in, and the window runs nothing.
    @Test @MainActor func anotherAccountInTheFolderReadsSoUnderEveryCodeThatHidesIt() throws {
        let folders = FolderAccountsTests()
        let (t, context) = try folders.setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try folders.link(context)
        let tool = try Self.loggingTool(in: t.home)
        let vm = ManageViewModel(
            context: context, runner: CLIRunner(context: context, candidates: [tool.exe]),
            clock: { Self.now })
        vm.windowOpened()
        let store = ConfigStore(context: context)
        let folder = try FolderPaths.configDir(context: context, label: "spare")
        let account = try #require(try store.loadRequired().account("spare"))
        let other = AuthObservation(
            FolderKind.evaluate(
                AuthStatus(
                    loggedIn: true, email: "other@example.com", planTier: "max_20x",
                    configDirectory: folder.path), account: account, folder: folder, now: Date()))

        func after(_ observations: StatusObservations) throws -> (String?, String?, String?) {
            let row = try Self.row(
                try StatusBuilder.rebuild(context: context, observations: observations), "spare")
            vm.statusMayHaveChanged()
            return (row.error?.code, row.planTier, row.signInCheck)
        }
        func expectOther(_ place: String) throws {
            #expect(try Self.seen(vm, "spare") == .otherAccount, "\(place)")
            vm.selection = "spare"
            let panel = try #require(vm.panel)
            #expect(panel.problem?.title == "Wrong account", "\(place)")
            // Ended, it says that too.
            let end = place == "under account_ended" ? " Account ended." : ""
            #expect(panel.problem?.text == Messages.wrongAccount + end, "\(place)")
            #expect(panel.problem?.steps.steps == [Messages.signExpectedBackIn], "\(place)")
            // The other account's plan never shows on this account's line.
            #expect(panel.emailLine == "acct@example.com", "\(place)")
        }

        var got = try after(StatusObservations(auth: ["spare": other]))
        #expect(got.0 == "wrong_account" && got.1 == nil && got.2 == "other_account")
        try expectOther("alone")
        got = try after(
            StatusObservations(settings: SettingsObservation(issue: "changed", carriesKey: false)))
        #expect(got.0 == "settings_changed" && got.1 == nil && got.2 == "other_account")
        try expectOther("under settings_changed")
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "spare" })
        config.accounts[index].endsAt = "2026-01-01"
        try store.save(config)
        got = try after(StatusObservations())
        #expect(got.0 == "account_ended" && got.1 == nil && got.2 == "other_account")
        try expectOther("under account_ended")
        config.accounts[index].endsAt = nil
        try store.save(config)
        got = try after(
            StatusObservations(settings: SettingsObservation(issue: nil, carriesKey: false)))
        #expect(got.0 == "wrong_account" && got.2 == "other_account")
        try expectOther("settings accepted")
        #expect(Self.lines(tool.log).isEmpty)
    }

    /// An entry written before the check result was kept, with another account's tier from a
    /// `wrong_account` check: the row leaves that tier out, so a hidden code cannot turn the
    /// window green.
    @Test @MainActor func aWrongAccountTierKeptByAnOlderWriterIsNoEvidence() throws {
        let folders = FolderAccountsTests()
        let (t, context) = try folders.setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try folders.link(context)
        let folder = try FolderPaths.configDir(context: context, label: "spare")
        let account = try #require(
            try ConfigStore(context: context).loadRequired().account("spare"))
        let placed = AuthObservation(
            FolderKind.evaluate(
                AuthStatus(
                    loggedIn: true, email: account.email, planTier: "max_20x",
                    configDirectory: folder.path), account: account, folder: folder, now: Date()))
        _ = try StatusBuilder.rebuild(
            context: context, observations: StatusObservations(auth: ["spare": placed]))

        // Rewrite the entry as the older writer left it after a wrong-account check.
        let reader = NoFollowReader(root: context.dataRoot)
        let data = try #require(try reader.read(folders: Layout.stateFolders, name: "current.json"))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var accounts = try #require(object["accounts"] as? [String: Any])
        var entry = try #require(accounts["spare"] as? [String: Any])
        #expect(entry["planTier"] as? String == "max_20x")
        entry["authError"] = ["code": "wrong_account", "text": Messages.wrongAccount]
        entry.removeValue(forKey: "signInCheck")
        accounts["spare"] = entry
        object["accounts"] = accounts
        try NoFollowWriter(root: context.dataRoot).put(
            try JSONSerialization.data(withJSONObject: object), folders: Layout.stateFolders,
            name: "current.json")

        let row = try Self.row(
            try StatusBuilder.rebuild(
                context: context,
                observations: StatusObservations(
                    settings: SettingsObservation(issue: "changed", carriesKey: false))), "spare")
        #expect(row.error?.code == "settings_changed")
        #expect(row.planTier == nil && row.signInCheck == nil)
        let tool = try Self.loggingTool(in: t.home)
        let vm = ManageViewModel(
            context: context, runner: CLIRunner(context: context, candidates: [tool.exe]),
            clock: { Self.now })
        vm.windowOpened()
        #expect(try Self.seen(vm, "spare") == .notSignedIn)
    }

    /// An entry an earlier version wrote after a `check_failed` check kept the plan tier and
    /// recorded no sign-in check. The row leaves that tier out, so neither that code nor a code
    /// that ranks above it can turn the window green.
    @Test @MainActor func aCheckFailedTierKeptByAnEarlierVersionIsNoEvidence() throws {
        let folders = FolderAccountsTests()
        let (t, context) = try folders.setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try folders.link(context)
        let store = ConfigStore(context: context)
        let folder = try FolderPaths.configDir(context: context, label: "spare")
        let account = try #require(try store.loadRequired().account("spare"))
        let placed = AuthObservation(
            FolderKind.evaluate(
                AuthStatus(
                    loggedIn: true, email: account.email, planTier: "max_20x",
                    configDirectory: folder.path), account: account, folder: folder, now: Date()))
        _ = try StatusBuilder.rebuild(
            context: context, observations: StatusObservations(auth: ["spare": placed]))

        // Rewrite the entry as an earlier version left it after a check that failed.
        let reader = NoFollowReader(root: context.dataRoot)
        let data = try #require(try reader.read(folders: Layout.stateFolders, name: "current.json"))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var accounts = try #require(object["accounts"] as? [String: Any])
        var entry = try #require(accounts["spare"] as? [String: Any])
        #expect(entry["planTier"] as? String == "max_20x")
        entry["authError"] = [
            "code": "check_failed", "text": "Check failed: the sign-in is not in its own folder.",
        ]
        entry.removeValue(forKey: "signInCheck")
        accounts["spare"] = entry
        object["accounts"] = accounts
        try NoFollowWriter(root: context.dataRoot).put(
            try JSONSerialization.data(withJSONObject: object), folders: Layout.stateFolders,
            name: "current.json")

        let tool = try Self.loggingTool(in: t.home)
        let vm = ManageViewModel(
            context: context, runner: CLIRunner(context: context, candidates: [tool.exe]),
            clock: { Self.now })
        vm.windowOpened()
        /// A rebuild with what one command saw, then the row and the window for the folder.
        func expectNoSignIn(_ observations: StatusObservations, code: String) throws {
            let row = try Self.row(
                try StatusBuilder.rebuild(context: context, observations: observations), "spare")
            #expect(row.error?.code == code)
            #expect(row.planTier == nil && row.signInCheck == nil, "\(code)")
            vm.statusMayHaveChanged()
            let shown = try Self.shown(vm, "spare", kind: Kind.folder)
            #expect(shown.panel != "Signed in" && !shown.list.hasPrefix("Signed in"), "\(shown)")
            #expect(!shown.panelGreen && !shown.listGreen, "\(code): \(shown)")
        }

        // The code alone, then under each code that ranks above it.
        try expectNoSignIn(StatusObservations(), code: "check_failed")
        try expectNoSignIn(
            StatusObservations(settings: SettingsObservation(issue: "changed", carriesKey: false)),
            code: "settings_changed")
        var config = try store.loadRequired()
        config.accounts.append(
            Account(label: "twin", kind: Kind.token, role: Role.pool, email: account.email))
        try store.save(config)
        try expectNoSignIn(
            StatusObservations(settings: SettingsObservation(issue: nil, carriesKey: false)),
            code: "duplicate_login")
        config.accounts.removeAll { $0.label == "twin" }
        let index = try #require(config.accounts.firstIndex { $0.label == "spare" })
        config.accounts[index].endsAt = Self.pastDay
        try store.save(config)
        try expectNoSignIn(StatusObservations(), code: "account_ended")
        #expect(Self.lines(tool.log).isEmpty)
    }
}
