import Foundation
import Testing

@testable import Core

/// An account whose `noLimit` says its plan has no 5-hour limit: while its reading has no 5-hour
/// window the picker judges it on its weekly use, the registry takes the key only as
/// `["five_hour"]`, and the status row carries it only while it is set.
/// The texts name local times, so the expectations are written for UTC.
@Suite(.localZone("UTC")) struct NoLimitTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let noFiveHourLimit = [WindowName.fiveHour]

    func reading(
        week: Double, five: Double? = 10, resetDays: Double = 3, readAge: TimeInterval = 60,
        source: String = ReadingSource.probe
    ) -> Reading {
        var windows = [
            WindowName.sevenDay: WindowReading(
                usedPercent: week, resetsAt: Self.now.addingTimeInterval(resetDays * 86_400),
                readAt: Self.now)
        ]
        if let five {
            windows[WindowName.fiveHour] = WindowReading(
                usedPercent: five, resetsAt: Self.now.addingTimeInterval(3_600), readAt: Self.now)
        }
        return Reading(
            source: source, readAt: Self.now.addingTimeInterval(-readAge), windows: windows)
    }

    func pool(_ label: String, set: Bool = false, _ tune: (inout Account) -> Void = { _ in })
        -> Account
    {
        var a = Account(label: label, kind: Kind.token, role: Role.pool)
        if set { a.noLimit = Self.noFiveHourLimit }
        tune(&a)
        return a
    }

    func main(kind: String = Kind.login, set: Bool = true) -> Account {
        var a = Account(label: "main", kind: kind, role: Role.main)
        if set { a.noLimit = Self.noFiveHourLimit }
        return a
    }

    func decide(_ inputs: [PickInput], model: PickModel = .other, leases: [String: Int] = [:])
        -> PickDecision
    {
        Picker.decide(
            inputs: inputs, config: Config(), model: model, openLeases: leases, now: Self.now)
    }

    func reason(_ d: PickDecision, _ label: String) -> String {
        d.candidates.first { $0.label == label }?.reason ?? ""
    }

    func time(days: Double) -> String {
        Picker.shortTime(Self.now.addingTimeInterval(days * 86_400))
    }

    // MARK: The pick

    @Test func aSetPoolAccountWithNoWindowRanksWithTheKnownAccounts() {
        let goLast = " Accounts with no 5-hour reading go last."
        let known = PickInput(account: pool("k"), reading: reading(week: 10, resetDays: 4))
        func u(
            set: Bool = true, week: Double = 10, days: Double = 1,
            _ tune: (inout Account) -> Void = { _ in }
        ) -> PickInput {
            PickInput(
                account: pool("u", set: set, tune),
                reading: reading(week: week, five: nil, resetDays: days))
        }
        for order in [[u(), known], [known, u()]] {
            let d = decide(order)
            #expect(d.chosen.map { order[$0].account.label } == "u")
            #expect(d.candidates.map(\.eligible) == [true, true])
            #expect(d.reason == "Soonest weekly reset: resets \(time(days: 1)).")
            #expect(reason(d, "u") == "Resets \(time(days: 1)).")
            #expect(reason(d, "k") == "Resets \(time(days: 4)).")
        }
        // Unset, the same account goes last and says why.
        let unset = decide([u(set: false), known])
        #expect(unset.chosen == 1)
        #expect(unset.reason == "Soonest weekly reset: resets \(time(days: 4))." + goLast)
        #expect(reason(unset, "u") == "Resets \(time(days: 1)). 5-hour use unknown.")
        // A later reset than the known account's goes after it, with no note.
        let later = decide([u(days: 5), known])
        #expect(later.chosen == 1)
        #expect(later.reason == "Soonest weekly reset: resets \(time(days: 4)).")
        // On an equal reset minute, more weekly room wins, then config order.
        let sameMinute = PickInput(account: pool("k"), reading: reading(week: 20, resetDays: 1))
        #expect(decide([sameMinute, u(week: 10)]).chosen == 1)
        #expect(decide([sameMinute, u(week: 30)]).chosen == 0)
        #expect(decide([sameMinute, u(week: 20)]).chosen == 0)
        #expect(decide([u(week: 20), sameMinute]).chosen == 0)
        // Marked ending soon, it ranks inside the group as if it ended in two days.
        let soon = decide([known, u(days: 6) { $0.endingSoon = true }])
        #expect(soon.chosen == 1)
        #expect(soon.reason == "Soonest expiry: ends \(time(days: 2)).")
        // An unset account with no window still goes last, even with a sooner reset.
        let x = PickInput(account: pool("x"), reading: reading(week: 10, five: nil, resetDays: 0.5))
        let mixed = decide([x, u()])
        #expect(mixed.chosen == 1)
        #expect(mixed.reason == "Soonest weekly reset: resets \(time(days: 1))." + goLast)
        #expect(reason(mixed, "x") == "Resets \(time(days: 0.5)). 5-hour use unknown.")
        // A Fable pick keeps its note and says nothing of 5-hour use.
        let fable = decide([u(), known], model: .fable)
        #expect(fable.chosen == 0)
        #expect(
            fable.reason
                == "Soonest weekly reset: resets \(time(days: 1)). Fable room guaranteed at 80% of cap."
        )
    }

    @Test func aSetMainAccountWithNoWindowIsJudgedOnItsWeeklyUse() {
        for kind in Kind.all {
            func go(
                _ week: Double, set: Bool = true, leases: Int = 0, model: PickModel = .other,
                fable: Bool = true
            ) -> PickDecision {
                var account = main(kind: kind, set: set)
                if !fable { account.fable = AccountFable(allowLaunches: false) }
                let input = PickInput(
                    account: account, reading: reading(week: week, five: nil, resetDays: 7))
                return decide([input], model: model, leases: ["main": leases])
            }
            let ok = go(45)
            #expect(ok.chosen == 0, "\(kind)")
            #expect(ok.reason == "Soonest weekly reset: resets \(time(days: 7)).", "\(kind)")
            #expect(reason(ok, "main") == "Resets \(time(days: 7)).", "\(kind)")
            let over = go(45.1)
            #expect(over.chosen == nil, "\(kind)")
            #expect(
                reason(over, "main")
                    == "Weekly use 45.1% is above the reserve line of 50.0% minus a 5 point margin.",
                "\(kind)")
            #expect(go(35, leases: 2).chosen == 0, "\(kind)")
            let leased = go(35, leases: 3)
            #expect(leased.chosen == nil, "\(kind)")
            #expect(
                reason(leased, "main")
                    == "Weekly use 50.0% is above the reserve line of 50.0% minus a 5 point margin.",
                "\(kind)")
            let fable = go(10, model: .fable)
            #expect(fable.chosen == 0, "\(kind)")
            #expect(
                fable.reason
                    == "Soonest weekly reset: resets \(time(days: 7)). Fable room guaranteed at 80% of cap.",
                "\(kind)")
            let noFable = go(10, model: .fable, fable: false)
            #expect(noFable.chosen == nil, "\(kind)")
            #expect(
                reason(noFable, "main") == "Fable launches not allowed on the main account.",
                "\(kind)")
            let unset = go(10, set: false)
            #expect(unset.chosen == nil, "\(kind)")
            #expect(
                reason(unset, "main") == "No 5-hour reading, which the main account needs.",
                "\(kind)")
        }
    }

    @Test func aFiveHourWindowCountsWhateverTheSetting() {
        var readings = [10, 89, 90.1, 92, 95].map { reading(week: 10, five: $0) }
        var open = reading(week: 10)
        open.windows[WindowName.fiveHour]?.resetsAt = nil
        var passed = reading(week: 10)
        passed.windows[WindowName.fiveHour]?.resetsAt = Self.now.addingTimeInterval(-1)
        readings += [open, passed]
        let unknown = PickInput(account: pool("x"), reading: reading(week: 10, five: nil))
        for r in readings {
            for role in Role.all {
                for model in [PickModel.other, .fable] {
                    for leases in [0, 2] {
                        let unset = Account(label: "a", kind: Kind.login, role: role)
                        var set = unset
                        set.noLimit = Self.noFiveHourLimit
                        for others in [[], [unknown]] {
                            let without = decide(
                                [PickInput(account: unset, reading: r)] + others, model: model,
                                leases: ["a": leases])
                            let with = decide(
                                [PickInput(account: set, reading: r)] + others, model: model,
                                leases: ["a": leases])
                            let note =
                                "\(r.fiveHour?.usedPercent ?? -1) \(role) \(model) \(leases) \(others.count)"
                            #expect(with == without, "\(note)")
                        }
                    }
                }
            }
        }
        // The table reaches each 5-hour rule.
        func setReason(_ role: String, _ r: Reading) -> String {
            var a = Account(label: "a", kind: Kind.login, role: role)
            a.noLimit = Self.noFiveHourLimit
            return reason(decide([PickInput(account: a, reading: r)]), "a")
        }
        #expect(setReason(Role.main, readings[3]) == "5-hour use 92.0% leaves no room for a run.")
        #expect(setReason(Role.pool, readings[4]) == "Limited until \(time(days: 1.0 / 24)).")
        #expect(setReason(Role.main, passed) == "window reset, refresh failed")
        #expect(setReason(Role.main, open) == "Resets \(time(days: 3)).")
    }

    @Test func theSettingSkipsNoEarlierCheck() {
        var noWeek = reading(week: 10, five: nil)
        noWeek.windows[WindowName.sevenDay] = nil
        var weekReset = reading(week: 10, five: nil)
        weekReset.windows[WindowName.sevenDay]?.resetsAt = Self.now.addingTimeInterval(-1)
        let cases:
            [(
                name: String, roles: [String], reading: Reading?, endsAt: String?, skip: String?,
                text: String
            )] = [
                ("no reading", Role.all, nil, nil, nil, "no weekly reading"),
                ("no weekly window", Role.all, noWeek, nil, nil, "no weekly reading"),
                (
                    "estimate reading", [Role.main],
                    reading(week: 10, five: nil, source: ReadingSource.estimate), nil, nil,
                    "No probe reading, which the main account needs."
                ),
                (
                    "stale reading", Role.all, reading(week: 10, five: nil, readAge: 1_000), nil,
                    nil, "stale reading, refresh failed"
                ),
                (
                    "weekly reset passed", Role.all, weekReset, nil, nil,
                    "window reset, refresh failed"
                ),
                (
                    "weekly use at the limit", Role.all, reading(week: 95, five: nil), nil, nil,
                    "Limited until \(time(days: 3))."
                ),
                (
                    "ended", Role.all, reading(week: 10, five: nil), "2000-01-01", nil,
                    "Account ended."
                ),
                (
                    "caller skip", Role.all, reading(week: 10, five: nil), nil,
                    "excluded by caller", "excluded by caller"
                ),
            ]
        for c in cases {
            for role in c.roles {
                var unset = Account(label: "a", kind: Kind.login, role: role)
                unset.endsAt = c.endsAt
                var set = unset
                set.noLimit = Self.noFiveHourLimit
                let without = decide([PickInput(account: unset, reading: c.reading, skip: c.skip)])
                let with = decide([PickInput(account: set, reading: c.reading, skip: c.skip)])
                #expect(with.chosen == nil, "\(c.name) \(role)")
                #expect(reason(with, "a") == c.text, "\(c.name) \(role)")
                #expect(reason(with, "a") == reason(without, "a"), "\(c.name) \(role)")
            }
        }
    }

    // MARK: The registry

    func validation(_ names: [String]?, kind: String = Kind.token, role: String = Role.pool)
        -> String?
    {
        let account = Account(label: "spare", kind: kind, role: role, noLimit: names)
        do {
            try ConfigValidator.validate(Config(accounts: [account]))
            return nil
        } catch let e as ToolError { return e.message } catch { return "other" }
    }

    @Test func noLimitLoadsOnlyAsFiveHour() throws {
        let refused = #"Account 'spare': noLimit must be ["five_hour"]."#
        for kind in Kind.all {
            for role in Role.all {
                #expect(validation(nil, kind: kind, role: role) == nil, "\(kind) \(role)")
                #expect(validation(["five_hour"], kind: kind, role: role) == nil, "\(kind) \(role)")
            }
        }
        for names in [
            [], ["seven_day"], ["five_hour", "five_hour"], ["Five_Hour"], ["fiveHour"],
            ["five_hour", "seven_day"],
        ] {
            #expect(validation(names) == refused, "\(names)")
        }

        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        func load(_ value: String?) throws -> Account? {
            let key = value.map { #","noLimit":"# + $0 } ?? ""
            let json =
                #"{"schemaVersion":1,"accounts":[{"label":"spare","kind":"token","role":"pool","accountKey":"k1""#
                + key + "}]}"
            try NoFollowWriter(root: t.context.dataRoot).put(
                Data(json.utf8), folders: [], name: ConfigStore.fileName)
            return try store.loadRequired().accounts.first
        }
        func failure(_ value: String) -> String? {
            do {
                _ = try load(value)
                return nil
            } catch let e as ToolError { return e.message } catch { return "other" }
        }
        for wrongType in [#""five_hour""#, "true", "1", #"{"five_hour":true}"#] {
            #expect(
                failure(wrongType) == "config.json has a missing or wrong-typed field.",
                "\(wrongType)")
        }
        for value in ["[]", #"["seven_day"]"#, #"["five_hour","five_hour"]"#] {
            #expect(failure(value) == refused, "\(value)")
        }
        #expect(try load(nil)?.noLimit == nil)
        #expect(try load("null")?.noLimit == nil)
        #expect(try load(#"["five_hour"]"#)?.noLimit == ["five_hour"])

        func encoded(_ account: Account) throws -> [String: Any] {
            try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
        }
        #expect(try encoded(pool("spare"))["noLimit"] == nil)
        #expect(try encoded(pool("spare", set: true))["noLimit"] as? [String] == ["five_hour"])
    }

    @Test func aSaveKeepsAndDropsNoLimit() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        var config = Config(accounts: [
            Account(
                label: "spare", kind: Kind.token, role: Role.pool, accountKey: "k1",
                noLimit: ["five_hour"])
        ])
        try store.save(config)
        #expect(try store.load() == config)
        config.accounts[0].noLimit = nil
        try store.save(config)
        #expect(try store.load() == config)
        let raw = try Data(
            contentsOf: t.context.dataRoot.appendingPathComponent(ConfigStore.fileName))
        let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let account = try #require((object["accounts"] as? [[String: Any]])?.first)
        #expect(account["noLimit"] == nil)
        #expect(account["accountKey"] as? String == "k1")
    }

    // MARK: The status

    /// A set main account with no 5-hour window and a token pool account whose reading has one
    /// and resets a day later.
    func statusWithASetMainAccount() -> StatusBuild {
        let main = Account(
            label: "main", kind: Kind.login, role: Role.main, email: "main@example.com",
            expectedPlanTier: "max_20x", accountKey: "key-main", noLimit: ["five_hour"])
        let pool = Account(
            label: "pool-a", kind: Kind.token, role: Role.pool, accountKey: "key-pool-a")
        var observations = StatusObservations()
        observations.auth["main"] = AuthObservation(
            error: nil, planTier: "max_20x",
            loginExpiresAt: Self.now.addingTimeInterval(30 * 86_400), signedIn: true)
        return StatusBuilder.build(
            config: Config(accounts: [main, pool]),
            readings: [
                "main": reading(week: 10, five: nil, resetDays: 2),
                "pool-a": reading(week: 10, resetDays: 3),
            ],
            previous: CurrentFile(), observations: observations, sessions: .empty,
            tokens: ["pool-a": TokenInfo(usable: true, modified: Self.now)],
            launchExists: { _ in true }, now: Self.now)
    }

    @Test func aStatusRowCarriesNoLimitOnlyWhileSet() throws {
        let built = statusWithASetMainAccount()
        let data = try StatusDocument.encoder().encode(built.document)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(object["accounts"] as? [[String: Any]])
        let main = try #require(rows.first { $0["label"] as? String == "main" })
        let pool = try #require(rows.first { $0["label"] as? String == "pool-a" })
        #expect(main["noLimit"] as? [String] == ["five_hour"])
        #expect(main["fiveHour"] is NSNull)
        #expect(pool["noLimit"] == nil)
        let next = built.document.next
        #expect(next.all.label == "main")
        #expect(next.all.reason == "Soonest weekly reset: resets \(time(days: 2)).")
        #expect(next.fable.label == "main")
        #expect(!next.fable.reason.contains("5-hour"))
    }

    @Test func theMenuReadsAStatusWithNoLimit() throws {
        let data = try StatusDocument.encoder().encode(statusWithASetMainAccount().document)
        guard case .loaded(let snapshot) = StatusSnapshot.parse(data) else {
            Issue.record("The status with a noLimit row did not load.")
            return
        }
        #expect(snapshot.accounts.map(\.label) == ["main", "pool-a"])
    }
}
