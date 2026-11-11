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
