import Foundation
import Testing

@testable import Core

/// The status document, pinned by golden files for each error and warning code of
/// docs/ARCHITECTURE.md section 9 that exists in this version.
/// The texts name local times, so the golden files are written for UTC.
@Suite(.localZone("UTC")) struct StatusBuilderTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-09T21:10:00Z") ?? Date()
    let now = StatusBuilderTests.now
    static let goldenFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/golden")

    func account(
        _ label: String = "main", kind: String = Kind.login, role: String = Role.pool,
        email: String? = nil, key: String? = nil, endingSoon: Bool? = nil, endsAt: String? = nil
    ) -> Account {
        Account(
            label: label, kind: kind, role: role, email: email ?? "\(label)@example.com",
            expectedPlanTier: "max_20x", accountKey: key ?? "key-\(label)", endsAt: endsAt,
            endingSoon: endingSoon)
    }

    func reading(
        weekly: Double = 22, five: Double? = 9, fable: FableReading? = nil, ageMinutes: Double = 4
    ) -> Reading {
        let at = now.addingTimeInterval(-ageMinutes * 60)
        var windows = [
            WindowName.sevenDay: WindowReading(
                usedPercent: weekly, resetsAt: now.addingTimeInterval(2 * 86_400), readAt: at)
        ]
        if let five {
            windows[WindowName.fiveHour] = WindowReading(
                usedPercent: five, resetsAt: now.addingTimeInterval(9_000), readAt: at)
        }
        return Reading(readAt: at, windows: windows, fable: fable)
    }

    func build(
        _ accounts: [Account], readings: [String: Reading] = [:],
        previous: CurrentFile = CurrentFile(), observations: StatusObservations = .init(),
        sessions: SessionsSnapshot = .empty, tokens: [String: TokenInfo] = [:],
        launchExists: @escaping (LaunchRef) -> Bool = { _ in true },
        tune: (inout Config) -> Void = { _ in }
    ) -> StatusBuild {
        var config = Config(accounts: accounts)
        tune(&config)
        return StatusBuilder.build(
            config: config, readings: readings, previous: previous, observations: observations,
            sessions: sessions, tokens: tokens, launchExists: launchExists, now: now)
    }

    func golden(_ name: String, _ document: StatusDocument) throws {
        let data = try StatusDocument.encoder().encode(document) + Data([0x0A])
        let url = Self.goldenFolder.appendingPathComponent("status-\(name).json")
        guard let saved = FileManager.default.contents(atPath: url.path) else {
            try data.write(to: url)
            Issue.record("Recorded the golden file status-\(name).json. Review it and run again.")
            return
        }
        #expect(
            String(decoding: saved, as: UTF8.self) == String(decoding: data, as: UTF8.self),
            "golden status-\(name).json")
    }

    func authError(_ code: StateCode, _ text: String) -> StatusObservations {
        StatusObservations(auth: [
            "main": AuthObservation(
                error: Issue(code, .error, text), planTier: "max_20x", loginExpiresAt: nil,
                signedIn: code != .loginRejected)
        ])
    }

    func row(_ built: StatusBuild, _ index: Int = 0) -> AccountStatus {
        built.document.accounts[index]
    }

    // MARK: The healthy row

    @Test func anOkRowCarriesTheStableFields() throws {
        let a = account(role: Role.main)
        var obs = StatusObservations()
        obs.auth["main"] = AuthObservation(
            error: nil, planTier: "max_20x", loginExpiresAt: now.addingTimeInterval(30 * 86_400),
            signedIn: true)
        let built = build([a], readings: ["main": reading()], observations: obs)
        let r = row(built)
        #expect(r.state == "ok" && r.error == nil && r.limited == nil)
        #expect(r.role == "main" && r.kind == "login" && r.fullLogin)
        #expect(r.configDir == nil && r.linked == nil && r.accountKey == "key-main")
        #expect(r.weekly.usedPercent == 22 && r.weekly.source == "probe")
        #expect(r.fable.source == "estimate" && r.fable.usedPercent == nil)
        #expect(r.fable.guaranteedLeftPercentOfCap == 56 && r.fable.possibleLeftPercentOfCap == 100)
        #expect(r.reserve != nil)
        #expect(r.loginExpiresSource == "auth" && r.planTier == "max_20x")
        #expect(r.inUse.count == 0)
        try golden("ok-main", built.document)
    }

    @Test func aProbeFableReadingReplacesTheEstimate() throws {
        let fable = FableReading(
            source: ReadingSource.probe, usedPercent: 30, resetsAt: now.addingTimeInterval(3_600),
            readAt: now, weeklyUsedPercentAtRead: 22)
        let built = build([account()], readings: ["main": reading(fable: fable)])
        let f = row(built).fable
        #expect(f.source == "probe" && f.usedPercent == 30)
        #expect(f.guaranteedLeftPercentOfCap == nil && f.possibleLeftPercentOfCap == nil)
    }

    @Test func anAccountWithNoReadingShowsNoneAndNoSince() throws {
        let built = build([account()])
        let r = row(built)
        #expect(r.weekly == .none && r.fiveHour == nil && r.stateSince == nil)
        #expect(r.fable.source == "none" && r.readingsAge == nil)
    }

    // MARK: One golden file per code

    @Test func loginRejected() throws {
        let built = build(
            [account()], readings: ["main": reading()],
            observations: authError(.loginRejected, "Login rejected."))
        #expect(row(built).error?.code == "login_rejected" && row(built).state == "error")
        try golden("login-rejected", built.document)
    }

    @Test func wrongAccount() throws {
        let built = build(
            [account()], readings: ["main": reading()],
            observations: authError(.wrongAccount, "Folder is logged in as another account."))
        #expect(row(built).error?.code == "wrong_account")
        try golden("wrong-account", built.document)
    }

    @Test func duplicateLoginShowsOnBothAccounts() throws {
        let built = build(
            [
                account("main", email: "same@example.com"),
                account("pool-a", kind: Kind.token, email: "SAME@example.com"),
            ], tokens: ["pool-a": TokenInfo(usable: true, modified: now)])
        #expect(row(built, 0).error?.code == "duplicate_login")
        #expect(row(built, 1).error?.code == "duplicate_login")
        #expect(row(built, 0).error?.text.contains("pool-a") == true)
        try golden("duplicate-login", built.document)
    }

    @Test func settingsChangedShowsOneBanner() throws {
        var obs = StatusObservations()
        obs.settings = SettingsObservation(issue: "missing", carriesKey: false)
        let built = build(
            [account("main"), account("pool-a", kind: Kind.token)],
            readings: ["main": reading()], observations: obs,
            tokens: ["pool-a": TokenInfo(usable: true, modified: now)])
        #expect(built.document.banner?.code == "settings_changed")
        #expect(built.document.banner?.text == Messages.hookRecordMissing)
        #expect(row(built, 0).error?.text == Messages.hookRecordMissing)
        #expect(row(built, 1).error?.code == "settings_changed")
        // One error event per affected account.
        #expect(built.events.filter { $0.code == "settings_changed" }.count == 2)
        try golden("settings-changed-missing", built.document)

        obs.settings = SettingsObservation(issue: "changed", carriesKey: false)
        let changed = build([account()], readings: ["main": reading()], observations: obs)
        #expect(row(changed).error?.text == Messages.settingsChanged)
        try golden("settings-changed", changed.document)
    }

    @Test func planChanged() throws {
        let built = build(
            [account()], readings: ["main": reading()],
            observations: authError(.planChanged, "Plan is max_5x, expected max_20x."))
        #expect(row(built).error?.code == "plan_changed")
        try golden("plan-changed", built.document)
    }

    @Test func checkFailed() throws {
        var obs = StatusObservations()
        obs.probe["main"] = ProbeObservation(
            error: Issue(.checkFailed, .error, "Check failed: probe timed out after 60 s."))
        let built = build([account()], readings: ["main": reading()], observations: obs)
        #expect(row(built).error?.code == "check_failed")
        try golden("check-failed", built.document)
    }

    @Test func accountEndedByDate() throws {
        let built = build([account(endsAt: "2026-11-01")], readings: ["main": reading()])
        #expect(row(built).state == "ended" && row(built).error?.code == "account_ended")
        try golden("account-ended", built.document)
    }

    @Test func limitedNamesTheWindowWithTheLatestReset() throws {
        let built = build([account()], readings: ["main": reading(weekly: 97, five: 96)])
        let r = row(built)
        #expect(r.state == "limited" && r.error == nil)
        #expect(r.limited?.window == "weekly")
        #expect(r.limited?.until == now.addingTimeInterval(2 * 86_400))
        #expect(r.limited?.since == now)
        try golden("limited", built.document)
        #expect(built.events.map(\.type) == ["account_added", "limited"])
    }

    @Test func fableLimitedIsAWarningOnAnOkRow() throws {
        let fable = FableReading(
            source: ReadingSource.probe, usedPercent: 97, resetsAt: now.addingTimeInterval(7_200),
            readAt: now, weeklyUsedPercentAtRead: 22)
        let built = build([account()], readings: ["main": reading(fable: fable)])
        let r = row(built)
        #expect(r.state == "ok" && r.warnings.map(\.code) == ["fable_limited"])
        try golden("fable-limited", built.document)
    }

    @Test func loginExpiringWarnsWithinSevenDays() throws {
        var obs = StatusObservations()
        obs.auth["main"] = AuthObservation(
            error: nil, planTier: "max_20x", loginExpiresAt: now.addingTimeInterval(3 * 86_400),
            signedIn: true)
        let built = build([account()], readings: ["main": reading()], observations: obs)
        #expect(row(built).warnings.map(\.code) == ["login_expiring"])
        #expect(built.events.last?.type == "login_expiring")
        try golden("login-expiring", built.document)
    }

    @Test func keyInSettingsIsAWarningWithNoEvent() throws {
        var obs = StatusObservations()
        obs.settings = SettingsObservation(issue: nil, carriesKey: true)
        let built = build([account()], readings: ["main": reading()], observations: obs)
        #expect(row(built).warnings.map(\.code) == ["key_in_settings"])
        #expect(built.events.map(\.type) == ["account_added"])
        try golden("key-in-settings", built.document)
    }

    @Test func staleWarnsWhenTheReadingIsOlderThanTwiceTheRefreshInterval() throws {
        let built = build([account()], readings: ["main": reading(ageMinutes: 190)])
        #expect(row(built).warnings.map(\.code) == ["stale"])
        #expect(row(built).warnings.first?.text == "Last read 3 h ago.")
        #expect(row(built).readingsAge == 190 * 60)
        try golden("stale", built.document)
    }

    @Test func aMissingLaunchFileIsACountOnTheLabel() throws {
        let ref = LaunchRef(label: "pool-a", leaseId: "l-0a0a0a0a")
        let sessions = SessionsSnapshot(
            clean: true, live: [LiveSession(id: "s-1", name: "w1", refs: [ref])], named: [ref])
        let built = build(
            [account("pool-a", kind: Kind.token)], sessions: sessions,
            tokens: ["pool-a": TokenInfo(usable: true, modified: now)], launchExists: { _ in false }
        )
        let r = row(built)
        #expect(r.state == "ok" && r.warnings.map(\.code) == ["launch_file_missing"])
        #expect(r.warnings.first?.text == "1 live session names a launch file that is gone.")
        #expect(built.events.map(\.type) == ["account_added"])
        try golden("launch-file-missing", built.document)
    }

    // MARK: Ending soon

    @Test func anEndingSoonAccountWhosePlanDropsIsEndedNotPlanChanged() throws {
        let a = account(endingSoon: true)
        let obs = StatusObservations(auth: [
            "main": AuthObservation(
                error: Issue(.planChanged, .error, "Plan is pro, expected max_20x."),
                planTier: "pro", loginExpiresAt: nil, signedIn: true)
        ])
        let built = build([a], readings: ["main": reading()], observations: obs)
        #expect(row(built).state == "ended" && row(built).error?.code == "account_ended")
        // It stays ended on a later cached rebuild, until the mark is turned off.
        let again = build([a], readings: ["main": reading()], previous: built.current)
        #expect(row(again).state == "ended")
        // With the mark off the account is no longer ended; the plan mismatch is a plain error.
        let cleared = build([account()], readings: ["main": reading()], previous: again.current)
        #expect(row(cleared).state == "error" && row(cleared).error?.code == "plan_changed")
        #expect(cleared.events.last?.type == "error")
        try golden("account-ended-ending-soon", built.document)
    }

    @Test func aMissingPlanTierEndsAnEndingSoonAccount() throws {
        let obs = StatusObservations(auth: [
            "main": AuthObservation(
                error: Issue(.planChanged, .error, "Plan is unknown, expected max_20x."),
                planTier: nil, loginExpiresAt: nil, signedIn: true)
        ])
        let built = build(
            [account(endingSoon: true)], readings: ["main": reading()], observations: obs)
        #expect(row(built).error?.code == "account_ended")
    }

    @Test func aRejectedLoginOnAnEndingSoonAccountStaysLoginRejectedWithBothCases() throws {
        let built = build(
            [account(endingSoon: true)], readings: ["main": reading()],
            observations: authError(.loginRejected, "Login rejected."))
        #expect(row(built).error?.code == "login_rejected")
        let text = row(built).error?.text ?? ""
        #expect(text.contains("Login rejected") && text.contains("plan has ended"))
        try golden("login-rejected-ending-soon", built.document)
    }

    // MARK: Token accounts

    @Test func aTokenRowIsEstimatedAndNeverHoldsAPlanTier() throws {
        let a = account("pool-a", kind: Kind.token, email: "note@example.com")
        let modified = now.addingTimeInterval(-100 * 86_400)
        let built = build(
            [a], readings: ["pool-a": reading()],
            tokens: ["pool-a": TokenInfo(usable: true, modified: modified)])
        let r = row(built)
        #expect(r.fullLogin == false && r.planTier == nil && r.email == "note@example.com")
        #expect(r.loginExpiresSource == "estimate")
        #expect(r.loginExpiresAt == modified.addingTimeInterval(365 * 86_400))
        try golden("token-ok", built.document)
    }

    @Test func aTokenWithinFourteenDaysOfItsEstimatedEndWarns() throws {
        let a = account("pool-a", kind: Kind.token)
        let modified = now.addingTimeInterval(-355 * 86_400)
        let built = build(
            [a], readings: ["pool-a": reading()],
            tokens: ["pool-a": TokenInfo(usable: true, modified: modified)])
        #expect(row(built).warnings.map(\.code) == ["login_expiring"])
    }

    // MARK: Next

    @Test func nextFollowsThePickerRulesWithoutLeasesOrAges() throws {
        let a = account("pool-a", kind: Kind.token)
        let b = account("pool-b", kind: Kind.token)
        var soon = reading(weekly: 30)
        soon.windows[WindowName.sevenDay]?.resetsAt = now.addingTimeInterval(3_600)
        let built = build(
            [a, b], readings: ["pool-a": reading(ageMinutes: 600), "pool-b": soon],
            tokens: [
                "pool-a": TokenInfo(usable: true, modified: now),
                "pool-b": TokenInfo(usable: true, modified: now),
            ])
        #expect(built.document.next.all.label == "pool-b")
        #expect(built.document.next.fable.label == "pool-b")
        #expect(!built.document.next.all.reason.isEmpty)
    }

    @Test func nextSkipsAnAccountInError() throws {
        let built = build(
            [account()], readings: ["main": reading()],
            observations: authError(.loginRejected, "Login rejected."))
        #expect(built.document.next.all.label == nil)
        #expect(built.document.next.all.reason.contains("main"))
    }

    @Test func statusNextRefusesAMainAccountWithNoFiveHourReading() throws {
        let missing = "No 5-hour reading, which the main account needs."
        let main = account(role: Role.main)
        var obs = StatusObservations()
        obs.auth["main"] = AuthObservation(
            error: nil, planTier: "max_20x", loginExpiresAt: now.addingTimeInterval(30 * 86_400),
            signedIn: true)
        let noFive = reading(weekly: 10, five: nil)
        let alone = build([main], readings: ["main": noFive], observations: obs)
        #expect(row(alone).fiveHour == nil)
        #expect(row(alone).reserve?.launchAllowed == true)
        for choice in [alone.document.next.all, alone.document.next.fable] {
            #expect(choice.label == nil)
            #expect(choice.reason == "No account has room. main: " + missing)
        }
        let pool = account("pool-a", kind: Kind.token)
        var known = reading()
        known.windows[WindowName.sevenDay]?.resetsAt = now.addingTimeInterval(3 * 86_400)
        let both = build(
            [main, pool], readings: ["main": noFive, "pool-a": known], observations: obs,
            tokens: ["pool-a": TokenInfo(usable: true, modified: now)])
        #expect(both.document.next.all.label == "pool-a")
        #expect(both.document.next.fable.label == "pool-a")
        let resets = Picker.shortTime(now.addingTimeInterval(3 * 86_400))
        #expect(both.document.next.all.reason == "Soonest weekly reset: resets \(resets).")
    }

    // MARK: In use

    @Test func inUseCountsASessionByIdTowardTheLabelItsLaunchFileNames() throws {
        let ref = LaunchRef(label: "pool-a", leaseId: "l-0a0a0a0a")
        let sessions = SessionsSnapshot(
            clean: true,
            live: [
                LiveSession(id: "11111111-aaaa", name: "w1", refs: [ref]),
                LiveSession(id: "22222222-bbbb", name: "w2", refs: [ref]),
                LiveSession(id: "33333333-cccc", name: "mine", refs: []),
            ], named: [ref])
        let built = build(
            [account("main"), account("pool-a", kind: Kind.token)], sessions: sessions,
            tokens: ["pool-a": TokenInfo(usable: true, modified: now)])
        #expect(row(built, 1).inUse.count == 2)
        #expect(row(built, 1).inUse.sessions.map(\.id) == ["11111111", "22222222"])
        #expect(
            row(built, 0).inUse.count == 1 && row(built, 0).inUse.sessions.first?.name == "mine")
    }

    @Test func inUseIsUnknownWhenTheRecordsCannotBeRead() throws {
        let built = build([account()], sessions: .unreadable)
        #expect(row(built).inUse == .unknownValue)
        let data = try StatusDocument.encoder().encode(built.document)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"unknown\" : true"))
    }

    @Test func aSessionNamingAnUnconfiguredLabelCountsNowhere() throws {
        let ref = LaunchRef(label: "gone", leaseId: "l-0a0a0a0a")
        let sessions = SessionsSnapshot(
            clean: true, live: [LiveSession(id: "s-1", name: "x", refs: [ref])], named: [ref])
        let built = build([account()], sessions: sessions)
        #expect(row(built).inUse.count == 0)
    }

    // MARK: Leaks

    @Test func noFieldHoldsATokenOrAPathOfOne() throws {
        let a = account("pool-a", kind: Kind.token)
        let built = build(
            [a], readings: ["pool-a": reading()],
            tokens: ["pool-a": TokenInfo(usable: true, modified: now)])
        let text = String(
            decoding: try StatusDocument.encoder().encode(built.document), as: UTF8.self)
        #expect(!text.contains(TokenPaths.folders[0] + "/"))
        let launchFolder = LaunchFiles.rootURL(context: try TestHome().context).lastPathComponent
        #expect(!text.contains(launchFolder + "/"))
        #expect(!text.contains("sk-" + "ant"))
    }

    @Test func errorTextsAreScrubbedOfEmailsAndTokens() throws {
        let email = Canaries.email()
        let token = Canaries.oauth()
        let built = build(
            [account()], readings: ["main": reading()],
            observations: authError(.checkFailed, "Check failed for \(email) with \(token)."))
        let text = String(
            decoding: try StatusDocument.encoder().encode(built.document), as: UTF8.self)
        #expect(!text.contains(email) && !text.contains(token))
    }
}

/// The token account's expiry estimate and its sign-in error.
extension StatusBuilderTests {
    func tokenAccount(createdDaysAgo days: Double?) -> Account {
        var a = Account(
            label: "tok", kind: Kind.token, role: Role.pool, accountKey: "key-tok")
        if let days {
            a.tokenCreatedAt = ISO8601DateFormatter().string(
                from: now.addingTimeInterval(-days * 86_400))
        }
        return a
    }

    func tokenBuild(
        _ a: Account, previous: CurrentFile = CurrentFile(),
        observations: StatusObservations = .init()
    ) -> StatusBuild {
        build(
            [a], readings: ["tok": reading()], previous: previous, observations: observations,
            tokens: ["tok": TokenInfo(usable: true, modified: now)])
    }

    @Test func aTokenEstimateCountsAYearAndSaysEstimate() {
        let built = tokenBuild(tokenAccount(createdDaysAgo: 10))
        let r = row(built)
        #expect(r.loginExpiresSource == "estimate")
        let expected = now.addingTimeInterval(355 * 86_400)
        let at = r.loginExpiresAt
        #expect(abs((at ?? .distantPast).timeIntervalSince(expected)) < 2)
        #expect(r.warnings.isEmpty)
    }

    @Test func aTokenWarnsFourteenDaysBeforeItsYearEnds() {
        #expect(
            row(tokenBuild(tokenAccount(createdDaysAgo: 351))).warnings.map(\.code) == [
                "login_expiring"
            ])
        #expect(
            row(tokenBuild(tokenAccount(createdDaysAgo: 360))).warnings.map(\.code) == [
                "login_expiring"
            ])
        #expect(
            row(tokenBuild(tokenAccount(createdDaysAgo: 351.5))).warnings.map(\.code) == [
                "login_expiring"
            ])
        #expect(row(tokenBuild(tokenAccount(createdDaysAgo: 350))).warnings.isEmpty)
        #expect(row(tokenBuild(tokenAccount(createdDaysAgo: 100))).warnings.isEmpty)
    }

    @Test func aLoginAccountStillWarnsOnlyWithinSevenDays() {
        var obs = StatusObservations()
        obs.auth["main"] = AuthObservation(
            error: nil, planTier: "max_20x", loginExpiresAt: now.addingTimeInterval(10 * 86_400),
            signedIn: true)
        let built = build([account()], readings: ["main": reading()], observations: obs)
        #expect(row(built).warnings.isEmpty)
    }

    @Test func theTokenExpiringEventIsWrittenOncePerExpiryDate() {
        let a = tokenAccount(createdDaysAgo: 355)
        let first = tokenBuild(a)
        #expect(first.events.filter { $0.type == "login_expiring" }.count == 1)
        let again = tokenBuild(a, previous: first.current)
        #expect(again.events.filter { $0.type == "login_expiring" }.isEmpty)
        // A replaced token moves the date; a new year then warns again once it is close.
        var renewed = a
        renewed.tokenCreatedAt = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(-352 * 86_400))
        let moved = tokenBuild(renewed, previous: first.current)
        #expect(moved.events.filter { $0.type == "login_expiring" }.count == 1)
    }

    @Test func aRejectedTokenShowsLoginRejected() {
        var obs = StatusObservations()
        obs.probe["tok"] = ProbeObservation(
            error: Issue(.loginRejected, .error, "Login rejected."))
        let built = tokenBuild(tokenAccount(createdDaysAgo: 10), observations: obs)
        let r = row(built)
        #expect(r.state == "error")
        #expect(r.error?.code == "login_rejected")
        #expect(built.events.contains { $0.type == "error" })
    }
}
