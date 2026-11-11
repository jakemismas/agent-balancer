import Foundation
import Testing

@testable import Core

@Suite struct ProbeReaderTests {
    let readAt = Date(timeIntervalSince1970: 1_800_000_000)

    func fixture(_ name: String) throws -> String {
        try TestHome().probeFixture(name, now: readAt)
    }

    func reading(_ name: String) throws -> Reading {
        guard case .reading(let r) = ProbeReader.parse(try fixture(name), readAt: readAt) else {
            Issue.record("expected a reading from \(name)")
            throw CancellationError()
        }
        return r
    }

    func failure(_ name: String) throws -> Core.Issue {
        guard case .failed(let issue) = ProbeReader.parse(try fixture(name), readAt: readAt) else {
            Issue.record("expected a failure from \(name)")
            throw CancellationError()
        }
        return issue
    }

    @Test func readsBothWindowsAsPercentWithOneDecimal() throws {
        let r = try reading("ok.jsonl")
        #expect(r.source == "probe")
        #expect(r.fiveHour?.usedPercent == 12.3)
        #expect(r.sevenDay?.usedPercent == 45.6)
        #expect(r.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_800_010_020))
        #expect(r.readAt == readAt)
        #expect(r.fable == nil)
    }

    @Test func readsTheFableWindowAsTheFableReading() throws {
        let r = try reading("fable.jsonl")
        #expect(r.fable?.source == "probe")
        #expect(r.fable?.usedPercent == 31.0)
        #expect(r.fable?.weeklyUsedPercentAtRead == 50.0)
        #expect(r.windows.keys.contains(WindowName.fable) == false)
    }

    @Test func keepsUnknownWindowNames() throws {
        let r = try reading("unknown_window.jsonl")
        #expect(r.windows["monthly_extra"]?.usedPercent == 50.0)
        #expect(r.sevenDay?.usedPercent == 30.0)
    }

    @Test func aValueOutsideTheScaleIsCheckFailed() throws {
        let issue = try failure("out_of_range.jsonl")
        #expect(issue.code == .checkFailed)
    }

    @Test func aFinalAuthErrorIsLoginRejected() throws {
        let issue = try failure("auth_error.jsonl")
        #expect(issue.code == .loginRejected)
        #expect(!issue.text.contains("Invalid API key"))
    }

    @Test func aMissingEventOrUnparsableOutputIsCheckFailed() throws {
        #expect(try failure("no_event.jsonl").code == .checkFailed)
        #expect(try failure("garbage.txt").code == .checkFailed)
        guard case .failed(let issue) = ProbeReader.parse("", readAt: readAt) else {
            Issue.record("expected a failure")
            return
        }
        #expect(issue.code == .checkFailed)
    }

    @Test func eventsWithoutAUsageValueAreCheckFailedNotAnEmptyReading() throws {
        #expect(try failure("status_only.jsonl").code == .checkFailed)
    }

    @Test func theEdgesOfTheScaleAreAccepted() {
        func line(_ u: String) -> String {
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":"
                + "{\"seven_day\":{\"utilization\":\(u),\"resetsAt\":1800400000}}}}"
        }
        for (text, want) in [("0", 0.0), ("1", 100.0), ("0.0449", 4.5)] {
            guard case .reading(let r) = ProbeReader.parse(line(text), readAt: readAt) else {
                Issue.record("expected a reading for \(text)")
                continue
            }
            #expect(r.sevenDay?.usedPercent == want)
        }
        for bad in ["-0.1", "1.01", "\"0.5\"", "true", "null"] {
            guard case .failed(let issue) = ProbeReader.parse(line(bad), readAt: readAt) else {
                Issue.record("expected a failure for \(bad)")
                continue
            }
            #expect(issue.code == .checkFailed)
        }
    }

    @Test func readsTheFlatEventForm() {
        let text =
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"rateLimitType\":\"five_hour\","
            + "\"utilization\":0.25,\"resetsAt\":1800010000}}"
        guard case .reading(let r) = ProbeReader.parse(text, readAt: readAt) else {
            Issue.record("expected a reading")
            return
        }
        #expect(r.fiveHour?.usedPercent == 25.0)
    }

    @Test func otherLinesAreDroppedUnread() throws {
        let r = try reading("ok.jsonl")
        let text = String(decoding: try Reading.encoder().encode(r), as: UTF8.self)
        #expect(!text.contains("example.com"))
        #expect(!text.contains("/tmp/probe"))
    }

    @Test func aWindowNameThatIsNotPlainIsDropped() {
        let text =
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":"
            + "{\"seven_day\":{\"utilization\":0.1,\"resetsAt\":1800010000},"
            + "\"someone@example.com\":{\"utilization\":0.2,\"resetsAt\":1800010000}}}}"
        guard case .reading(let r) = ProbeReader.parse(text, readAt: readAt) else {
            Issue.record("expected a reading")
            return
        }
        #expect(Set(r.windows.keys) == ["seven_day"])
    }

    // Reset-time bounds (ResetBounds): five_hour allows 5 h, seven_day and the Fable window 7 d,
    // an unknown name 31 d, each with 300 s of slack on both sides of the probe time.

    func event(_ name: String, resets: String?) -> String {
        let reset = resets.map { ",\"resetsAt\":\($0)" } ?? ""
        return "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":"
            + "{\"\(name)\":{\"utilization\":0.5\(reset)}}}}"
    }

    func offset(_ seconds: Int) -> String { "\(1_800_000_000 + seconds)" }

    func parses(_ name: String, _ resets: String?) -> Reading? {
        if case .reading(let r) = ProbeReader.parse(event(name, resets: resets), readAt: readAt) {
            return r
        }
        return nil
    }

    @Test func resetTimesAtTheEdgesOfEachWindowAreAccepted() {
        let day = 86_400
        let cases: [(String, Int, Int)] = [
            ("five_hour", -300, 5 * 3600 + 300),
            ("seven_day", -300, 7 * day + 300),
            (WindowName.fable, -300, 7 * day + 300),
            ("monthly_extra", -300, 31 * day + 300),
        ]
        for (name, low, high) in cases {
            #expect(parses(name, offset(low)) != nil, "\(name) low edge")
            #expect(parses(name, offset(high)) != nil, "\(name) high edge")
            #expect(parses(name, offset(low - 60)) == nil, "\(name) just below")
            #expect(parses(name, offset(high + 60)) == nil, "\(name) just above")
        }
    }

    @Test func anOutOfRangeResetTimeFailsTheReading() {
        for bad in [
            "1e300", "-1e300", "1e999", "-1e999", "4102444800", "0", "-1",
            "\"not a date\"", "\"9999-12-31T00:00:00Z\"", "true", "[1]", "{}",
        ] {
            guard
                case .failed(let issue) = ProbeReader.parse(
                    event("seven_day", resets: bad), readAt: readAt)
            else {
                Issue.record("expected a failure for \(bad)")
                continue
            }
            #expect(issue.code == .checkFailed)
        }
    }

    @Test func aMillisecondResetTimeIsConvertedAndBounded() {
        let ms = "\((1_800_000_000 + 3600) * 1000)"
        #expect(
            parses("five_hour", ms)?.fiveHour?.resetsAt
                == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(parses("five_hour", "\((1_800_000_000 + 6 * 3600) * 1000)") == nil)
    }

    @Test func anIsoResetTimeIsAccepted() {
        let r = parses("five_hour", "\"2027-01-15T08:00:00Z\"")
        #expect(r?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(
            parses("five_hour", "\"2027-01-15T08:20:00Z\"")?.fiveHour?.resetsAt
                == Date(timeIntervalSince1970: 1_800_001_200))
    }

    @Test func anAbsentOrNullResetTimeIsUnknownNotAnError() {
        #expect(parses("seven_day", nil)?.sevenDay?.resetsAt == nil)
        #expect(parses("seven_day", "null")?.sevenDay != nil)
        #expect(parses("seven_day", "null")?.sevenDay?.resetsAt == nil)
    }

    @Test func aBadFableResetTimeFailsTheReading() {
        #expect(parses(WindowName.fable, "1e300") == nil)
    }
}
