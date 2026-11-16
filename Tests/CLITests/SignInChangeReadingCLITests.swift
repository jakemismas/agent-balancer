import Foundation
import Testing

@testable import Core

/// The reading a label holds before its sign-in changes, and the replies of the new sign-in.
enum SignInSwitch {
    /// A time on the minute, as a reading file stores a reset time.
    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    static func store(_ cli: CLIHome) -> ReadingStore {
        ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
    }

    /// Saves under `label` the old sign-in's reading, `age` seconds before `now`: weekly use 10
    /// percent with its reset a day out, 5-hour use 10 percent with its reset an hour out.
    static func storeOld(_ cli: CLIHome, _ label: String, age: TimeInterval, now: Date) throws {
        let at = now.addingTimeInterval(-age)
        let windows = [
            WindowName.sevenDay: WindowReading(
                usedPercent: 10, resetsAt: minute(now.addingTimeInterval(86_400)), readAt: at),
            WindowName.fiveHour: WindowReading(
                usedPercent: 10, resetsAt: minute(now.addingTimeInterval(3_600)), readAt: at),
        ]
        try store(cli).save(Reading(readAt: at, windows: windows), label: label)
    }

    /// Makes every probe reply weekly use `week` (0 to 1) with its reset 6 days out, and 5-hour
    /// use 20 percent with its reset 4 hours out. Returns the two reset times.
    @discardableResult
    static func reply(_ cli: CLIHome, week: Double, now: Date) throws -> (weekly: Date, five: Date)
    {
        let weekly = minute(now.addingTimeInterval(6 * 86_400))
        let five = minute(now.addingTimeInterval(4 * 3_600))
        let windows =
            #""seven_day":{"utilization":\#(week),"resetsAt":\#(Int(weekly.timeIntervalSince1970))},"#
            + #""five_hour":{"utilization":0.2,"resetsAt":\#(Int(five.timeIntervalSince1970))}"#
        try cli.fake(
            "probe.jsonl",
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"#
                + windows + "}}}\n")
        return (weekly, five)
    }

    /// A probe reply: weekly use `week` (0 to 1) with its reset `days` out, and 5-hour use `five`
    /// with its reset `hours` out.
    static func stream(week: Double, days: Double, five: Double, hours: Double, now: Date)
        -> String
    {
        let weekly = Int(minute(now.addingTimeInterval(days * 86_400)).timeIntervalSince1970)
        let short = Int(minute(now.addingTimeInterval(hours * 3_600)).timeIntervalSince1970)
        return
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"#
            + #""seven_day":{"utilization":\#(week),"resetsAt":\#(weekly)},"#
            + #""five_hour":{"utilization":\#(five),"resetsAt":\#(short)}}}}"# + "\n"
    }

    /// How many probes the fake `claude` has run.
    static func probes(_ cli: CLIHome) -> Int {
        cli.fakeRecord("args.log").split(separator: "\n").filter { $0.hasPrefix("-p ") }.count
    }

    static func answer(_ out: Support.Output) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
    }

    /// The reason the pick gave for `label`.
    static func reason(_ out: Support.Output, _ label: String) throws -> String? {
        let candidates = try #require(try answer(out)["candidates"] as? [[String: Any]])
        return candidates.first { $0["label"] as? String == label }?["reason"] as? String
    }
}

/// A new email on a `login` or `folder` account, and a new token on a token account, delete the
/// label's stored reading, so nothing read for the old sign-in judges the account.
@Suite struct SignInChangeReadingCLITests {
    /// A home with one `login` account `main`, signed in as main@example.com on its plan.
    func setUp(role: String) throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: [
            Account(
                label: "main", kind: Kind.login, role: role, email: "main@example.com",
                expectedPlanTier: "max_20x", reserve: role == Role.main ? .standard : nil)
        ])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        return cli
    }

    @Test func anEmailChangeOnALoginAccountDeletesItsReadingSoThePickProbesTheNewSignIn() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        let now = Date()
        // Fresh, so a pick that found it would run no probe.
        try SignInSwitch.storeOld(cli, "main", age: 60, now: now)
        let new = try SignInSwitch.reply(cli, week: 0.92, now: now)
        try cli.fakeFixture("wrong_account")
        #expect(try cli.run(["config", "set", "main", "email", "other@example.com"]).status == 0)
        #expect(try SignInSwitch.store(cli).load(label: "main") == nil)

        let probes = SignInSwitch.probes(cli)
        let pick = try cli.run(["pick", "--json", "--dry-run"])
        #expect(SignInSwitch.probes(cli) == probes + 1)
        #expect(pick.status == 2)
        #expect(
            try SignInSwitch.reason(pick, "main")
                == "Only 3.0% of the week is left, and 5% is needed.")
        let stored = try #require(try SignInSwitch.store(cli).load(label: "main"))
        #expect(stored.sevenDay?.usedPercent == 92 && stored.sevenDay?.resetsAt == new.weekly)
        #expect(stored.fiveHour?.usedPercent == 20 && stored.fiveHour?.resetsAt == new.five)
    }

    @Test func theSameEmailAgainKeepsTheStoredReading() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        let now = Date()
        try SignInSwitch.storeOld(cli, "main", age: 60, now: now)
        try SignInSwitch.reply(cli, week: 0.92, now: now)
        let file = cli.read("state/readings/main.json")
        #expect(!file.isEmpty)
        // The sign-in check compares emails without letter case, so neither is a new email.
        for email in ["main@example.com", "Main@Example.COM"] {
            #expect(try cli.run(["config", "set", "main", "email", email]).status == 0)
            #expect(cli.read("state/readings/main.json") == file, "\(email)")
        }

        let probes = SignInSwitch.probes(cli)
        let pick = try cli.run(["pick", "--json", "--dry-run"])
        #expect(SignInSwitch.probes(cli) == probes)
        #expect(pick.status == 0)
        #expect(try SignInSwitch.answer(pick)["label"] as? String == "main")
    }

    @Test func aMainAccountSignedIntoAnotherSubscriptionIsJudgedOnItsOwnWeeklyReset() throws {
        let cli = try setUp(role: Role.main)
        defer { cli.cleanup() }
        let now = Date()
        try SignInSwitch.storeOld(cli, "main", age: 1_200, now: now)
        try cli.fakeFixture("wrong_account")
        try SignInSwitch.reply(cli, week: 0.6, now: now)
        #expect(try cli.run(["config", "set", "main", "email", "other@example.com"]).status == 0)

        let pick = try cli.run(["pick", "--json", "--dry-run"])
        #expect(pick.status == 2)
        #expect(try SignInSwitch.answer(pick)["label"] is NSNull)
        #expect(
            try SignInSwitch.reason(pick, "main")
                == "Weekly use 60.0% is above the reserve line of 50.0% minus a 5 point margin.")
    }
}

extension FolderAccountsCLITests {
    @Test func anEmailChangeOnAFolderAccountDeletesItsReadingSoThePickProbesTheNewSignIn() throws {
        let cli = try setUp(login: false)
        defer { cli.cleanup() }
        try linked(cli)
        let now = Date()
        try SignInSwitch.storeOld(cli, "spare", age: 60, now: now)
        let new = try SignInSwitch.reply(cli, week: 0.92, now: now)
        try cli.fake("auth.json", try authJSON(cli, loggedIn: true, email: "new@example.com"))
        #expect(try cli.run(["config", "set", "spare", "email", "new@example.com"]).status == 0)
        #expect(try SignInSwitch.store(cli).load(label: "spare") == nil)

        let probes = SignInSwitch.probes(cli)
        let pick = try cli.run(["pick", "--json", "--dry-run"])
        #expect(SignInSwitch.probes(cli) == probes + 1)
        #expect(pick.status == 2)
        #expect(
            try SignInSwitch.reason(pick, "spare")
                == "Only 3.0% of the week is left, and 5% is needed.")
        let stored = try #require(try SignInSwitch.store(cli).load(label: "spare"))
        #expect(stored.sevenDay?.usedPercent == 92 && stored.sevenDay?.resetsAt == new.weekly)
        #expect(stored.fiveHour?.usedPercent == 20 && stored.fiveHour?.resetsAt == new.five)
    }
}

extension TokenAccountsCLITests {
    @Test func aTokenReplaceLeavesOnlyTheNewChecksReadingUnderTheLabel() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        // Each part would outlast a merge, so any part left after the replace is the old token's.
        let now = Date()
        let at = now.addingTimeInterval(-120)
        let old = [
            WindowName.sevenDay: WindowReading(
                usedPercent: 70, resetsAt: SignInSwitch.minute(now.addingTimeInterval(86_400)),
                readAt: at),
            WindowName.fiveHour: WindowReading(
                usedPercent: 50, resetsAt: SignInSwitch.minute(now.addingTimeInterval(3_600)),
                readAt: at),
            "seven_day_opus": WindowReading(
                usedPercent: 30,
                resetsAt: SignInSwitch.minute(now.addingTimeInterval(2 * 86_400)), readAt: at),
        ]
        let store = SignInSwitch.store(cli)
        try store.save(Reading(readAt: at, windows: old, fableProbedAt: at), label: "lab")
        let new = try SignInSwitch.reply(cli, week: 0.6, now: now)

        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        #expect(try events(cli, type: "token_replaced").count == 1)
        let stored = try #require(try store.load(label: "lab"))
        #expect(stored.readAt > at)
        #expect(Set(stored.windows.keys) == [WindowName.fiveHour, WindowName.sevenDay])
        #expect(stored.sevenDay?.usedPercent == 60 && stored.sevenDay?.resetsAt == new.weekly)
        #expect(stored.fiveHour?.usedPercent == 20 && stored.fiveHour?.resetsAt == new.five)
        #expect(stored.fableProbedAt == nil)
    }

    @Test func aFirstTokenSaveDeletesAReadingTheMissingTokenFileLeftBehind() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let now = Date()
        let old = Canary.realShapeToken()
        let fresh = Canary.realShapeToken()
        try cli.fake("token-stream-old.token", old)
        try cli.fake(
            "token-stream-old.jsonl",
            SignInSwitch.stream(week: 0.7, days: 1, five: 0.5, hours: 1, now: now))
        try cli.fake("token-stream-new.token", fresh)
        try cli.fake(
            "token-stream-new.jsonl",
            SignInSwitch.stream(week: 0.6, days: 6, five: 0.2, hours: 4, now: now))
        try cli.fake("setup-token.out", old + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        // Limited, so a rebuild that read the delete as a clear would record `limit_cleared`.
        try SignInRace.storeLimited(cli, "lab")
        #expect(try cli.run(["status", "--json"]).status == 0)
        #expect(try SignInRace.eventTypes(cli).last == "lab:limited")
        // A restore from a backup that leaves the tokens folder out keeps the reading.
        try FileManager.default.removeItem(at: try tokenFile(cli, "lab"))

        try cli.fake("setup-token.out", fresh + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        let stored = try #require(try SignInSwitch.store(cli).load(label: "lab"))
        #expect(stored.sevenDay?.usedPercent == 60)
        #expect(
            stored.sevenDay?.resetsAt == SignInSwitch.minute(now.addingTimeInterval(6 * 86_400)))
        #expect(stored.fiveHour?.usedPercent == 20)
        let types = try SignInRace.eventTypes(cli)
        #expect(!types.contains("lab:limit_cleared"))
        #expect(!types.contains("lab:token_replaced"))
    }
}
