import Foundation
import Testing

@testable import Core

/// The menu at the largest refresh interval the config accepts, at one past every bound, and with
/// status percents it cannot show.
extension ViewModelTests {
    static func agedRow(_ age: Int, weekly: String = "41.0", fable: String = "null") -> String {
        """
        { "label": "pool-a", "role": "pool", "state": "ok", "readingsAge": \(age),
          "weekly": { "usedPercent": \(weekly), "resetsAt": "2026-11-13T17:00:00Z", "source": "probe" },
          "fable": \(fable) }
        """
    }

    /// A reading is stale after two refresh intervals: two weeks at the largest interval.
    @Test func theStaleBoundHoldsAtTheLargestAcceptedInterval() throws {
        for (age, dimmed) in [(1_209_600, false), (1_209_601, true)] {
            let screen = Self.screen(Self.json(Self.agedRow(age)), minutes: 10_080)
            guard case .accounts(let a) = screen else {
                Issue.record("no rows at \(age)")
                continue
            }
            #expect(a.rows.first?.dimmed == dimmed, "\(age)")
        }
    }

    @Test func anIntervalPastEveryBoundStillBuildsTheRows() throws {
        let screen = Self.screen(Self.json(Self.agedRow(1_209_601)), minutes: .max)
        guard case .accounts(let a) = screen else {
            Issue.record("no rows")
            return
        }
        #expect(a.rows.first?.dimmed == false)
    }

    @Test(arguments: ["1e300", "-1e300", "100.5", "-1"])
    func aStatusPercentOutsideTheRangeReadsAsMissing(value: String) throws {
        let row = try #require(Self.rows(Self.json(Self.agedRow(0, weekly: value))).first)
        #expect(row.body == .note("Reading accounts"), "\(value)")
        let fable = "{ \"usedPercent\": \(value), \"source\": \"probe\" }"
        let withFable = try #require(Self.rows(Self.json(Self.agedRow(0, fable: fable))).first)
        guard case .meters(let meters) = withFable.body else {
            Issue.record("no meters for \(value)")
            return
        }
        #expect(meters.fable == nil, "\(value)")
        let estimate = "{ \"guaranteedLeftPercentOfCap\": \(value), \"source\": \"estimate\" }"
        let estimated = try #require(Self.rows(Self.json(Self.agedRow(0, fable: estimate))).first)
        guard case .meters(let guessed) = estimated.body else {
            Issue.record("no estimate for \(value)")
            return
        }
        #expect(guessed.fable?.valueText == "up to 100% used (est.)", "\(value)")
    }

    @Test(arguments: ["1e300", "100.1", "-0.1", "100", "0", "41.5"])
    func eachStatusPercentDecodesAsMissingOutsideTheRange(value: String) throws {
        let fields = ["usedPercent", "guaranteedLeftPercentOfCap", "possibleLeftPercentOfCap"]
            .map { "\"\($0)\": \(value)" }.joined(separator: ", ")
        let text = Self.json(Self.agedRow(0, weekly: value, fable: "{ \(fields) }"))
        guard case .loaded(let snapshot) = StatusSnapshot.parse(Data(text.utf8)) else {
            Issue.record("not loaded: \(value)")
            return
        }
        let account = try #require(snapshot.accounts.first)
        let number = try #require(Double(value))
        let kept: Double? = (0...100).contains(number) ? number : nil
        #expect(account.weekly?.usedPercent == kept, "\(value)")
        #expect(account.fable?.usedPercent == kept, "\(value)")
        #expect(account.fable?.guaranteedLeftPercentOfCap == kept, "\(value)")
        #expect(account.fable?.possibleLeftPercentOfCap == kept, "\(value)")
    }

    @Test func aStatusPercentAtEitherEndStillShows() throws {
        for value in ["0", "100"] {
            let row = try #require(Self.rows(Self.json(Self.agedRow(0, weekly: value))).first)
            guard case .meters(let meters) = row.body else {
                Issue.record("no meters for \(value)")
                continue
            }
            #expect(meters.all.valueText == "\(value)% used")
        }
    }

    @Test func aPercentTooLargeForAnIntFormatsWithoutATrap() {
        #expect(MenuFormat.percent(41.0) == "41%")
        #expect(MenuFormat.percent(12.5) == "12.5%")
        #expect(MenuFormat.percent(1e300).hasSuffix("%"))
    }
}

extension MenuControllerTests {
    /// The launch refresh follows the config's interval: a week at the largest one the config
    /// accepts, and the default hour for a config past every bound, which no longer loads.
    @Test @MainActor func theLaunchRefreshFollowsTheLargestAcceptedInterval() async throws {
        for (minutes, age) in [(10_080, 8.0 * 86_400), (Int.max, 3.0 * 3_600)] {
            let fake = try Fake()
            var config = Config()
            config.refresh.backgroundMinutes = minutes
            try fake.writeConfig(JSONEncoder().encode(config))
            try fake.writeStatus(generatedAt: Date().addingTimeInterval(-age))
            let controller = MenuController(context: fake.context, runner: fake.runner)
            controller.start()
            let saw = await Self.waitFor(300) { fake.calls().contains("refresh") }
            controller.stop()
            #expect(saw, "\(minutes)")
        }
    }
}
