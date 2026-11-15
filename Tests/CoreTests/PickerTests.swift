import Foundation
import Testing

@testable import Core

@Suite struct PickerTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func reading(
        week: Double, five: Double? = 10, resetDays: Double = 3, fable: FableReading? = nil,
        readAge: TimeInterval = 60, source: String = ReadingSource.probe
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
            source: source, readAt: Self.now.addingTimeInterval(-readAge), windows: windows,
            fable: fable)
    }

    func pool(_ label: String, _ tune: (inout Account) -> Void = { _ in }) -> Account {
        var a = Account(label: label, kind: Kind.token, role: Role.pool)
        tune(&a)
        return a
    }

    func main(_ label: String = "main") -> Account {
        Account(label: label, kind: Kind.login, role: Role.main, email: "main@example.com")
    }

    func decide(
        _ inputs: [PickInput], model: PickModel = .other, leases: [String: Int] = [:],
        tune: (inout Config) -> Void = { _ in }
    ) -> PickDecision {
        var config = Config()
        tune(&config)
        return Picker.decide(
            inputs: inputs, config: config, model: model, openLeases: leases, now: Self.now)
    }

    func reason(_ d: PickDecision, _ label: String) -> String {
        d.candidates.first { $0.label == label }?.reason ?? ""
    }

    // MARK: The reserve line

    @Test(arguments: [
        (7.0, 50.0), (5.0, 50.0), (4.5, 56.7), (4.0, 63.3), (3.5, 70.0), (3.0, 76.7),
        (2.5, 83.3), (2.0, 90.0), (1.0, 90.0), (0.5, 90.0),
    ])
    func theLineFollowsTheWorkedTable(days: Double, line: Double) {
        let got = Picker.reserveLine(.standard, daysLeft: days)
        #expect(abs(got - line) < 0.05)
    }

    @Test func theMainAccountLaunchesOnlyWhenUsePlusMarginIsUnderTheLine() {
        let ok = decide([PickInput(account: main(), reading: reading(week: 45, resetDays: 7))])
        #expect(ok.chosen == 0)
        let over = decide([PickInput(account: main(), reading: reading(week: 45.1, resetDays: 7))])
        #expect(over.chosen == nil)
        #expect(reason(over, "main").contains("reserve line"))
        let late = decide([PickInput(account: main(), reading: reading(week: 65, resetDays: 3.5))])
        #expect(late.chosen == 0)
    }

    @Test func theMainAccountNeedsFiveHourRoomForARun() {
        let blocked = decide([PickInput(account: main(), reading: reading(week: 10, five: 92))])
        #expect(blocked.chosen == nil)
        #expect(reason(blocked, "main").contains("5-hour"))
        let fine = decide([PickInput(account: main(), reading: reading(week: 10, five: 89))])
        #expect(fine.chosen == 0)
    }

    @Test func theMainAccountNeedsAProbeReading() {
        let d = decide([
            PickInput(
                account: main(), reading: reading(week: 10, source: ReadingSource.estimate))
        ])
        #expect(d.chosen == nil)
    }

    // MARK: Pool rules and ranking

    @Test func aPoolAccountNeedsRoomBelowTheLimitedLine() {
        let d = decide([
            PickInput(account: pool("a"), reading: reading(week: 89.9)),
            PickInput(account: pool("b"), reading: reading(week: 90)),
            PickInput(account: pool("c"), reading: reading(week: 95)),
        ])
        #expect(d.candidates.map(\.eligible) == [true, true, false])
        #expect(reason(d, "c").hasPrefix("Limited until"))
        let tight = decide([PickInput(account: pool("a"), reading: reading(week: 90.1))])
        #expect(tight.chosen == nil)
        #expect(reason(tight, "a").contains("is left"))
    }

    @Test func aFullFiveHourWindowLimitsAnAccount() {
        let d = decide([PickInput(account: pool("a"), reading: reading(week: 10, five: 95))])
        #expect(d.chosen == nil)
        #expect(reason(d, "a").hasPrefix("Limited until"))
    }

    @Test func theSoonestResetWinsThenTheMostRoomThenConfigOrder() {
        let soon = decide([
            PickInput(account: pool("a"), reading: reading(week: 10, resetDays: 4)),
            PickInput(account: pool("b"), reading: reading(week: 60, resetDays: 1)),
        ])
        #expect(soon.chosen == 1)
        let room = decide([
            PickInput(account: pool("a"), reading: reading(week: 50)),
            PickInput(account: pool("b"), reading: reading(week: 20)),
        ])
        #expect(room.chosen == 1)
        let order = decide([
            PickInput(account: pool("a"), reading: reading(week: 20)),
            PickInput(account: pool("b"), reading: reading(week: 20)),
        ])
        #expect(order.chosen == 0)
    }

    @Test func anEndingSoonAccountRanksAsIfItEndedInTwoDays() {
        let d = decide([
            PickInput(account: pool("a"), reading: reading(week: 10, resetDays: 3)),
            PickInput(
                account: pool("b") { $0.endingSoon = true },
                reading: reading(week: 10, resetDays: 6)),
        ])
        #expect(d.chosen == 1)
        #expect(d.reason.contains("ends"))
        // A known end that is sooner still ranks ahead of the assumption.
        var soonest = pool("c") { $0.endingSoon = true }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        soonest.endsAt = f.string(from: Self.now)
        let both = decide([
            PickInput(account: pool("b") { $0.endingSoon = true }, reading: reading(week: 10)),
            PickInput(account: soonest, reading: reading(week: 10, resetDays: 6)),
        ])
        #expect(both.chosen == 1)
    }

    @Test func anEndedAccountIsSkipped() {
        let d = decide([
            PickInput(
                account: pool("a") { $0.endsAt = "2000-01-01" }, reading: reading(week: 10))
        ])
        #expect(d.chosen == nil)
        #expect(reason(d, "a") == "Account ended.")
    }

    @Test func openLeasesAddExpectedRunUseSoCallersSpreadOut() {
        let inputs = [
            PickInput(account: pool("a"), reading: reading(week: 20)),
            PickInput(account: pool("b"), reading: reading(week: 22)),
        ]
        #expect(decide(inputs).chosen == 0)
        #expect(decide(inputs, leases: ["a": 1]).chosen == 1)
        let tight = decide(
            [PickInput(account: pool("a"), reading: reading(week: 80))], leases: ["a": 3])
        #expect(tight.chosen == nil)
    }

    @Test func nothingEligibleGivesNoLabelAndOneReasonPerAccount() {
        let d = decide([
            PickInput(account: pool("a"), reading: nil),
            PickInput(account: pool("b"), reading: reading(week: 10), skip: "excluded by caller"),
        ])
        #expect(d.chosen == nil)
        #expect(d.candidates.count == 2)
        #expect(reason(d, "a") == "no weekly reading")
        #expect(reason(d, "b") == "excluded by caller")
        #expect(d.reason.hasPrefix("No account has room."))
    }

    // MARK: Stale readings

    @Test func staleReadingsAreSkippedWithTheDocumentedReasons() {
        let old = decide([PickInput(account: pool("a"), reading: reading(week: 10, readAge: 1_000))]
        )
        #expect(reason(old, "a") == "stale reading, refresh failed")
        var passed = reading(week: 10)
        passed.windows[WindowName.sevenDay]?.resetsAt = Self.now.addingTimeInterval(-1)
        let reset = decide([PickInput(account: pool("a"), reading: passed)])
        #expect(reason(reset, "a") == "window reset, refresh failed")
        var noWeek = reading(week: 10)
        noWeek.windows[WindowName.sevenDay] = nil
        #expect(
            reason(decide([PickInput(account: pool("a"), reading: noWeek)]), "a")
                == "no weekly reading")
        var future = reading(week: 10)
        future.readAt = Self.now.addingTimeInterval(120)
        #expect(
            reason(decide([PickInput(account: pool("a"), reading: future)]), "a")
                == "stale reading, refresh failed")
    }

    // MARK: No 5-hour reading

    @Test func theMainAccountNeedsAFiveHourReading() {
        let missing = "No 5-hour reading, which the main account needs."
        let none = [PickInput(account: main(), reading: reading(week: 10, five: nil))]
        for d in [decide(none), decide(none, model: .fable), decide(none, leases: ["main": 1])] {
            #expect(d.chosen == nil)
            #expect(d.candidates.map(\.eligible) == [false])
            #expect(reason(d, "main") == missing)
            #expect(d.reason == "No account has room. main: " + missing)
        }
        // The 5-hour refusal comes before the Fable one.
        let noFable = decide(
            [PickInput(account: main().withFable(false), reading: reading(week: 10, five: nil))],
            model: .fable)
        #expect(noFable.chosen == nil)
        #expect(reason(noFable, "main") == missing)
        // The rule follows the role, whatever the kind.
        for kind in [Kind.token, Kind.folder] {
            let other = Account(label: "m", kind: kind, role: Role.main)
            let d = decide([PickInput(account: other, reading: reading(week: 10, five: nil))])
            #expect(d.chosen == nil, "\(kind)")
            #expect(reason(d, "m") == missing, "\(kind)")
        }
        let known = decide([PickInput(account: main(), reading: reading(week: 10, five: 10))])
        #expect(known.chosen == 0)
        let over = decide([
            PickInput(account: main(), reading: reading(week: 45.1, five: nil, resetDays: 7))
        ])
        #expect(over.chosen == nil)
        #expect(reason(over, "main").contains("reserve line"))
        #expect(reason(over, "main") != missing)
    }

    @Test func aFiveHourWindowWithNoResetTimeCountsAsPresent() {
        func noReset(_ five: Double) -> Reading {
            var r = reading(week: 10, five: five)
            r.windows[WindowName.fiveHour]?.resetsAt = nil
            return r
        }
        let open = decide([PickInput(account: main(), reading: noReset(10))])
        #expect(open.chosen == 0)
        #expect(!open.reason.contains("5-hour"))
        let full = decide([PickInput(account: main(), reading: noReset(92))])
        #expect(full.chosen == nil)
        #expect(reason(full, "main") == "5-hour use 92.0% leaves no room for a run.")
        let pooled = decide([PickInput(account: pool("a"), reading: noReset(10))])
        #expect(pooled.chosen == 0)
        #expect(!reason(pooled, "a").contains("5-hour"))
    }

    @Test(.localZone("UTC")) func aPoolAccountWithNoFiveHourReadingGoesLast() {
        let day = Picker.shortTime(Self.now.addingTimeInterval(86_400))
        let fourDays = Picker.shortTime(Self.now.addingTimeInterval(4 * 86_400))
        let unknown = PickInput(
            account: pool("u"), reading: reading(week: 10, five: nil, resetDays: 1))
        let goLast =
            "Soonest weekly reset: resets \(fourDays). Accounts with no 5-hour reading go last."
        let plain = "Soonest weekly reset: resets \(fourDays)."
        let knownPool = PickInput(
            account: pool("k"), reading: reading(week: 10, five: 10, resetDays: 4))
        for known in [
            knownPool,
            PickInput(account: main(), reading: reading(week: 10, five: 10, resetDays: 4)),
        ] {
            let d = decide([unknown, known])
            #expect(d.chosen == 1)
            #expect(d.candidates.map(\.eligible) == [true, true])
            #expect(reason(d, "u") == "Resets \(day). 5-hour use unknown.")
            #expect(reason(d, known.account.label) == "Resets \(fourDays).")
            #expect(d.reason == goLast)
            let flipped = decide([known, unknown])
            #expect(flipped.chosen == 0)
            #expect(flipped.reason == goLast)
        }
        let refused = decide([
            unknown,
            PickInput(account: pool("k"), reading: reading(week: 95, five: 10, resetDays: 4)),
            PickInput(account: main(), reading: reading(week: 95, five: 10, resetDays: 4)),
        ])
        #expect(refused.chosen == 0)
        #expect(refused.reason == "Soonest weekly reset: resets \(day). 5-hour use unknown.")
        // Within the group, the soonest reset still goes first, and only the note is added.
        let later = PickInput(
            account: pool("v"), reading: reading(week: 10, five: nil, resetDays: 2))
        let twoUnknown = decide([later, unknown])
        #expect(twoUnknown.chosen == 1)
        #expect(twoUnknown.reason == "Soonest weekly reset: resets \(day). 5-hour use unknown.")
        // A refused account with no 5-hour window is not passed over.
        for left in [
            PickInput(account: main(), reading: reading(week: 10, five: nil)),
            PickInput(account: pool("r"), reading: reading(week: 95, five: nil)),
        ] {
            let d = decide([left, knownPool])
            #expect(d.chosen == 1)
            #expect(d.reason == plain)
        }
        // An unknown account that resets later is still passed over.
        let lateUnknown = PickInput(
            account: pool("w"), reading: reading(week: 10, five: nil, resetDays: 5))
        #expect(decide([lateUnknown, knownPool]).reason == goLast)
        let twoKnown = decide([
            knownPool,
            PickInput(account: pool("m"), reading: reading(week: 10, five: 10, resetDays: 5)),
        ])
        #expect(twoKnown.chosen == 0)
        #expect(twoKnown.reason == plain)
        // A known account whose week has no reset time still ranks ahead of an unknown one.
        var open = reading(week: 10, five: 10)
        open.windows[WindowName.sevenDay]?.resetsAt = nil
        let openKnown = decide([unknown, PickInput(account: pool("o"), reading: open)])
        #expect(openKnown.chosen == 1)
        #expect(openKnown.reason.hasSuffix(". Accounts with no 5-hour reading go last."))
        // An unknown account marked ending soon, which ranks as ending in 2 days, still goes last.
        let endingSoon = PickInput(
            account: pool("e") { $0.endingSoon = true },
            reading: reading(week: 10, five: nil, resetDays: 3))
        for order in [[endingSoon, knownPool], [knownPool, endingSoon]] {
            let d = decide(order)
            #expect(d.chosen.map { order[$0].account.label } == "k")
            #expect(d.reason == goLast)
        }
        let fable = decide([unknown, knownPool], model: .fable)
        #expect(fable.chosen == 1)
        #expect(
            fable.reason
                == "Soonest weekly reset: resets \(fourDays). Fable room guaranteed at 80% of cap. Accounts with no 5-hour reading go last."
        )
    }

    @Test(.localZone("UTC")) func aLonePoolAccountWithNoFiveHourReadingIsPicked() {
        func lone(_ week: Double) -> [PickInput] {
            [PickInput(account: pool("a"), reading: reading(week: week, five: nil))]
        }
        let resets = Picker.shortTime(Self.now.addingTimeInterval(3 * 86_400))
        let d = decide(lone(10))
        #expect(d.chosen == 0)
        #expect(reason(d, "a") == "Resets \(resets). 5-hour use unknown.")
        #expect(d.reason == "Soonest weekly reset: resets \(resets). 5-hour use unknown.")
        let fable = decide(lone(10), model: .fable)
        #expect(fable.chosen == 0)
        #expect(
            fable.reason
                == "Soonest weekly reset: resets \(resets). Fable room guaranteed at 80% of cap. 5-hour use unknown."
        )
        // Ranked by ending soon rather than by its weekly reset, the pick still says so.
        let soon = decide([
            PickInput(
                account: pool("a") { $0.endingSoon = true }, reading: reading(week: 10, five: nil))
        ])
        #expect(soon.chosen == 0)
        let ends = Picker.shortTime(Self.now.addingTimeInterval(2 * 86_400))
        #expect(soon.reason == "Soonest expiry: ends \(ends). 5-hour use unknown.")
        let leased = decide(lone(80), leases: ["a": 3])
        #expect(leased.chosen == nil)
        #expect(reason(leased, "a") == "Only 0.0% of the week is left, and 5% is needed.")
        let tight = decide(lone(90.1))
        #expect(tight.chosen == nil)
        #expect(reason(tight, "a") == "Only 4.9% of the week is left, and 5% is needed.")
    }

    @Test func aStoredFiveHourWindowThatResetStillRefusesBothRoles() {
        var passed = reading(week: 10)
        passed.windows[WindowName.fiveHour]?.resetsAt = Self.now.addingTimeInterval(-1)
        for account in [main(), pool("a")] {
            let d = decide([PickInput(account: account, reading: passed)])
            #expect(d.chosen == nil)
            #expect(reason(d, account.label) == "window reset, refresh failed")
        }
    }

    // MARK: Fable

    func fableReading(used: Double, weekly: Double, age: TimeInterval = 60) -> FableReading {
        FableReading(
            source: ReadingSource.probe, usedPercent: used,
            resetsAt: Self.now.addingTimeInterval(86_400),
            readAt: Self.now.addingTimeInterval(-age),
            weeklyUsedPercentAtRead: weekly)
    }

    @Test func aFableReadingDecidesByPercentOfTheCap() {
        func go(_ used: Double) -> PickDecision {
            decide(
                [
                    PickInput(
                        account: pool("a"),
                        reading: reading(week: 40, fable: fableReading(used: used, weekly: 40)))
                ], model: .fable)
        }
        #expect(go(90).chosen == 0)
        #expect(go(90).reason.contains("Fable at least 10% of cap left."))
        #expect(go(90.1).chosen == nil)
        #expect(reason(go(96), "a").hasPrefix("Fable limited"))
    }

    @Test func aStaleFableReadingFailsClosed() {
        let aged = decide(
            [
                PickInput(
                    account: pool("a"),
                    reading: reading(
                        week: 40, fable: fableReading(used: 10, weekly: 40, age: 90_000)))
            ], model: .fable)
        #expect(aged.chosen == nil)
        let risen = decide(
            [
                PickInput(
                    account: pool("a"),
                    reading: reading(week: 46, fable: fableReading(used: 10, weekly: 40)))
            ], model: .fable)
        #expect(risen.chosen == nil)
        #expect(reason(risen, "a").contains("stale"))
        let small = decide(
            [
                PickInput(
                    account: pool("a"),
                    reading: reading(week: 44, fable: fableReading(used: 10, weekly: 40)))
            ], model: .fable)
        #expect(small.chosen == 0)
    }

    @Test func withoutAFableReadingOnlyGuaranteedRoomCounts() {
        let ok = decide([PickInput(account: pool("a"), reading: reading(week: 41))], model: .fable)
        #expect(ok.chosen == 0)
        let no = decide([PickInput(account: pool("a"), reading: reading(week: 46))], model: .fable)
        #expect(no.chosen == nil)
        #expect(
            reason(no, "a")
                == "Fable room not readable and not guaranteed above 50% weekly use.")
        let off = decide(
            [
                PickInput(
                    account: pool("a"),
                    reading: reading(week: 46, fable: fableReading(used: 1, weekly: 46)))
            ], model: .fable, tune: { $0.fable.probe = false })
        #expect(off.chosen == nil)
    }

    @Test func fableLaunchesCanBeSwitchedOffPerAccount() {
        let d = decide(
            [
                PickInput(
                    account: main().withFable(false), reading: reading(week: 10)),
                PickInput(account: pool("b"), reading: reading(week: 10)),
            ], model: .fable)
        #expect(d.chosen == 1)
        #expect(reason(d, "main") == "Fable launches not allowed on the main account.")
        let other = decide(
            [PickInput(account: main().withFable(false), reading: reading(week: 10))])
        #expect(other.chosen == 0)
    }

    @Test func modelNamesAreClassifiedAndValidated() {
        #expect(PickModel.parse("fable") == .fable)
        #expect(PickModel.parse("claude-fable-5") == .fable)
        #expect(PickModel.parse("opus") == .other)
        #expect(PickModel.parse(nil) == .other)
        #expect(PickModel.isValidName("sonnet[1m]"))
        #expect(!PickModel.isValidName("a b"))
        #expect(!PickModel.isValidName("x; rm"))
        #expect(!PickModel.isValidName(""))
    }

    @Test func theTypedStringsRefuseAQuoteInThePath() throws {
        #expect(try Recipe.launchArgs(settingsPath: "/a/b.json") == "--settings '/a/b.json'")
        #expect(throws: ToolError.self) { try Recipe.launchArgs(settingsPath: "/a/b'.json") }
        #expect(throws: ToolError.self) { try Recipe.launchArgs(settingsPath: "/a/\nb.json") }
        #expect(throws: ToolError.self) { try Recipe.launchArgs(settingsPath: "rel.json") }
    }
}

extension Account {
    fileprivate func withFable(_ allow: Bool) -> Account {
        var copy = self
        copy.fable = AccountFable(allowLaunches: allow)
        return copy
    }
}

/// The end rules rank a token account exactly as they rank a login account.
extension PickerTests {
    static func localDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    enum EndRule: CaseIterable {
        case none, endingSoon, endsToday

        func apply(_ account: inout Account) {
            switch self {
            case .none: break
            case .endingSoon: account.endingSoon = true
            case .endsToday: account.endsAt = PickerTests.localDay(PickerTests.now)
            }
        }
    }

    /// The position (0 or 1) pick chooses for two accounts with the same reading.
    func winner(_ first: Account, _ second: Account) -> (Int?, String) {
        let d = decide([
            PickInput(account: first, reading: reading(week: 10, resetDays: 6)),
            PickInput(account: second, reading: reading(week: 10, resetDays: 6)),
        ])
        return (d.chosen, d.reason)
    }

    @Test func theEndRulesRankATokenAccountAsTheyRankALoginAccount() {
        for firstRule in EndRule.allCases {
            for secondRule in EndRule.allCases {
                var answers: [Int?] = []
                for (firstKind, secondKind) in [(Kind.login, Kind.token), (Kind.token, Kind.login)]
                {
                    var first = Account(label: "first", kind: firstKind, role: Role.pool)
                    var second = Account(label: "second", kind: secondKind, role: Role.pool)
                    firstRule.apply(&first)
                    secondRule.apply(&second)
                    let (chosen, reason) = winner(first, second)
                    answers.append(chosen)
                    let marked = chosen == 0 ? firstRule : secondRule
                    #expect(reason.contains(marked == .none ? "weekly reset" : "ends"))
                }
                #expect(answers[0] == answers[1], "\(firstRule) then \(secondRule)")
            }
        }
        // The rules themselves: a mark moves the second account ahead, and a known end today
        // beats the ending-soon assumption of two days.
        for kinds in [(Kind.login, Kind.token), (Kind.token, Kind.login)] {
            let plain = Account(label: "plain", kind: kinds.0, role: Role.pool)
            var soon = Account(label: "soon", kind: kinds.1, role: Role.pool)
            EndRule.endingSoon.apply(&soon)
            #expect(winner(plain, soon).0 == 1)
            var today = Account(label: "today", kind: kinds.0, role: Role.pool)
            EndRule.endsToday.apply(&today)
            #expect(winner(soon, today).0 == 1)
            #expect(winner(today, soon).0 == 0)
            #expect(winner(plain, Account(label: "x", kind: kinds.1, role: Role.pool)).0 == 0)
        }
    }

    @Test func anEndedAccountIsSkippedWhateverItsKind() {
        for kind in [Kind.login, Kind.token] {
            let ended = Account(label: "gone", kind: kind, role: Role.pool, endsAt: "2000-01-01")
            let d = decide([PickInput(account: ended, reading: reading(week: 10))])
            #expect(d.chosen == nil)
            #expect(reason(d, "gone") == "Account ended.")
        }
    }
}
