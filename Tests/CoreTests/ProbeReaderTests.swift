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
            + "\"utilization\":0.25,\"resetsAt\":1800010000}}\n"
            + "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"rateLimitType\":\"seven_day\","
            + "\"utilization\":0.4,\"resetsAt\":1800400000}}"
        guard case .reading(let r) = ProbeReader.parse(text, readAt: readAt) else {
            Issue.record("expected a reading")
            return
        }
        #expect(r.fiveHour?.usedPercent == 25.0)
        #expect(r.sevenDay?.usedPercent == 40.0)
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

    // Reset-time bounds (ResetBounds): five_hour allows 5 h, every name that starts with seven_day
    // (the Fable window among them) 7 d, any other name 31 d, each with 300 s of slack on both
    // sides of the probe time.

    /// An event with window `name` at 50 percent. Any other name comes with a valid weekly window,
    /// because a reply without the weekly use is refused.
    func event(_ name: String, resets: String?) -> String {
        let reset = resets.map { ",\"resetsAt\":\($0)" } ?? ""
        let weekly =
            name == WindowName.sevenDay
            ? "" : "\"seven_day\":{\"utilization\":0.1,\"resetsAt\":\(offset(86_400))},"
        return "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
            + weekly + "\"\(name)\":{\"utilization\":0.5\(reset)}}}}"
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
            ("seven_day_opus", -300, 7 * day + 300),
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

    // Strict parse: every entry with a usage value is checked, whatever its name and whether the
    // cap keeps it, and a reply must carry the weekly use (and the 5-hour use when it names it).

    /// One unified event holding these entries, each value written as given.
    func unified(_ entries: [(String, String)]) -> String {
        "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
            + entries.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}}}"
    }

    /// A window entry with this usage (as JSON text) and a reset `seconds` after `readAt`.
    func entry(_ utilization: String, resetIn seconds: Int = 3_600) -> String {
        "{\"utilization\":\(utilization),\"resetsAt\":\(offset(seconds))}"
    }

    func parseFailure(_ text: String) -> Core.Issue? {
        if case .failed(let issue) = ProbeReader.parse(text, readAt: readAt) { return issue }
        return nil
    }

    var fiveHourEntry: (String, String) { (WindowName.fiveHour, entry("0.2")) }
    var sevenDayEntry: (String, String) { (WindowName.sevenDay, entry("0.3", resetIn: 86_400)) }

    @Test func aBadResetOnAnUnknownWindowFailsTheWholeReading() throws {
        let picker = [fiveHourEntry, sevenDayEntry]
        for bad in ["1e300", "\"not a date\"", offset(32 * 86_400 + 400)] {
            let text = unified(
                picker + [("monthly_extra", "{\"utilization\":0.5,\"resetsAt\":\(bad)}")])
            let issue = try #require(parseFailure(text), "reset \(bad)")
            #expect(issue.code == .checkFailed)
            #expect(issue.text == ProbeReader.badReset)
        }
        let good = unified(picker + [("monthly_extra", entry("0.5", resetIn: 30 * 86_400))])
        guard case .reading(let r) = ProbeReader.parse(good, readAt: readAt) else {
            Issue.record("expected a reading with a reset inside the window")
            return
        }
        #expect(r.windows["monthly_extra"]?.usedPercent == 50)
    }

    @Test func aNullUsageFailsTheWholeReadingOnAKnownWindowAndAnUnknownOne() throws {
        let null = "{\"utilization\":null,\"resetsAt\":\(offset(3_600))}"
        let replies: [[(String, String)]] = [
            [(WindowName.fiveHour, null), sevenDayEntry],
            [fiveHourEntry, (WindowName.sevenDay, null)],
            [fiveHourEntry, sevenDayEntry, (WindowName.fable, null)],
            [fiveHourEntry, sevenDayEntry, ("monthly_extra", null)],
        ]
        for entries in replies {
            let names = entries.map(\.0).joined(separator: " ")
            let issue = try #require(parseFailure(unified(entries)), "\(names)")
            #expect(issue.code == .checkFailed)
            #expect(issue.text == ProbeReader.badUsage, "\(names)")
        }
    }

    @Test func aBadValueOnANamePastTheCapStillFailsTheReading() throws {
        let others = (0..<20).map { String(format: "w%02d", $0) }
        let cases = [
            ("{\"utilization\":null}", ProbeReader.badUsage),
            ("{\"utilization\":\"0.5\"}", ProbeReader.badUsage),
            ("{\"utilization\":0.5,\"resetsAt\":1e300}", ProbeReader.badReset),
        ]
        for (bad, text) in cases {
            let entries =
                [fiveHourEntry, sevenDayEntry] + others.map { ($0, entry("0.1")) }
                + [("zz_last", bad)]
            #expect(parseFailure(unified(entries))?.text == text, "\(bad)")
        }
    }

    @Test func aReplyWithNoWeeklyUsageFails() {
        let flatFiveHour =
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"rateLimitType\":\"five_hour\","
            + "\"utilization\":0.25,\"resetsAt\":\(offset(3_600))}}"
        let replies = [
            unified([fiveHourEntry]),
            flatFiveHour,
            unified([fiveHourEntry, (WindowName.sevenDay, "{\"resetsAt\":\(offset(86_400))}")]),
            unified([fiveHourEntry, (WindowName.sevenDay, "null")]),
        ]
        for text in replies {
            #expect(parseFailure(text)?.text == ProbeReader.noWeekly, "\(text)")
        }
    }

    @Test func aNamedFiveHourWithNoUsageFails() {
        for fiveHour in ["{\"resetsAt\":\(offset(3_600))}", "null", "{\"status\":\"allowed\"}"] {
            let text = unified([(WindowName.fiveHour, fiveHour), sevenDayEntry])
            #expect(parseFailure(text)?.text == ProbeReader.noFiveHour, "\(fiveHour)")
        }
        // A status-only five_hour event beside an event that carries its value still reads.
        let flat =
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\","
            + "\"rateLimitType\":\"five_hour\"}}"
        let both = unified([fiveHourEntry, sevenDayEntry])
        guard case .reading(let r) = ProbeReader.parse(flat + "\n" + both, readAt: readAt) else {
            Issue.record("expected a reading")
            return
        }
        #expect(r.fiveHour?.usedPercent == 20)
        // A reply that does not name five_hour needs only the weekly use.
        guard
            case .reading(let weekly) = ProbeReader.parse(unified([sevenDayEntry]), readAt: readAt)
        else {
            Issue.record("expected a weekly reading")
            return
        }
        #expect(weekly.fiveHour == nil)
        #expect(weekly.sevenDay?.usedPercent == 30)
    }

    @Test func theCapKeepsThePickerWindowsAndTheFirstFourteenOtherNamesInNameOrder() {
        let others = (0..<20).map { String(format: "w%02d", $0) }
        let expected = Set([WindowName.fiveHour, WindowName.sevenDay] + others.prefix(14))
        for run in 0..<40 {
            let entries =
                others.map { ($0, entry("0.1")) } + [
                    fiveHourEntry, sevenDayEntry, (WindowName.fable, entry("0.4", resetIn: 86_400)),
                ]
            guard
                case .reading(let r) = ProbeReader.parse(
                    unified(entries.shuffled()), readAt: readAt)
            else {
                Issue.record("expected a reading on run \(run)")
                continue
            }
            #expect(Set(r.windows.keys) == expected, "run \(run)")
            #expect(r.fable?.usedPercent == 40, "run \(run)")
        }
        // Name order holds across events: later names in an earlier event do not win.
        let first = unified(others.suffix(15).map { ($0, entry("0.1")) })
        let second = unified(others.prefix(5).map { ($0, entry("0.1")) } + [sevenDayEntry])
        guard case .reading(let r) = ProbeReader.parse(first + "\n" + second, readAt: readAt)
        else {
            Issue.record("expected a reading from two events")
            return
        }
        #expect(Set(r.windows.keys) == Set([WindowName.sevenDay] + others.prefix(14)))
    }

    static let windowLengths: [(String, Int)] = [
        ("five_hour", 5 * 3600), ("seven_day", 7 * 86_400), (WindowName.fable, 7 * 86_400),
        ("seven_day_opus", 7 * 86_400), ("monthly_extra", 31 * 86_400),
    ]

    @Test func aResetWhoseRoundedMinuteFallsOutsideTheRangeFailsTheReading() {
        let slack = Int(ResetBounds.slack)
        // Read 40 s past a minute, a reset 5 s inside the upper bound rounds 20 s past it; read
        // 20 s past a minute, a reset 5 s inside the lower bound rounds 15 s before it.
        let late = 1_800_000_040
        let early = 1_800_000_020
        let cases: [(Int, Int, Int, String)] = [
            (late, late + 5 * 3600 + slack - 5, late + 5 * 3600 + slack - 40, "upper"),
            (early, early - slack + 5, early - slack + 40, "lower"),
        ]
        for (read, outside, inside, edge) in cases {
            let at = Date(timeIntervalSince1970: TimeInterval(read))
            let result = ProbeReader.parse(
                event(WindowName.fiveHour, resets: "\(outside)"), readAt: at)
            #expect(result == .failed(Issue(.checkFailed, .error, ProbeReader.badReset)), "\(edge)")
            // A time whose minute also lies inside is read.
            guard
                case .reading(let r) = ProbeReader.parse(
                    event(WindowName.fiveHour, resets: "\(inside)"), readAt: at)
            else {
                Issue.record("a reset inside the \(edge) bound was refused")
                continue
            }
            #expect(
                r.fiveHour?.resetsAt
                    == ProbeReader.minute(Date(timeIntervalSince1970: TimeInterval(inside))))
        }
    }

    @Test func aWindowRepeatedInOneReplyIsMergedByItsOwnWindowLength() {
        // An unknown name's window is 31 days long, so a reset 20 days out holds it in the reply.
        let first = event("monthly_extra", resets: offset(20 * 86_400))
        let second =
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
            + "\"monthly_extra\":{\"utilization\":0.05,\"resetsAt\":\(offset(3_600))}}}}"
        guard case .reading(let r) = ProbeReader.parse(first + "\n" + second, readAt: readAt)
        else {
            Issue.record("expected a reading from two events")
            return
        }
        #expect(r.windows["monthly_extra"]?.usedPercent == 50)
        #expect(
            r.windows["monthly_extra"]?.resetsAt
                == Date(timeIntervalSince1970: 1_800_000_000 + 20 * 86_400))
    }

    @Test func aWindowAPickReadsRepeatedInOneReplyNeverKeepsTheLowerUse() {
        func entry(_ name: String, _ utilization: String, resets: Int?) -> String {
            "\"\(name)\":{\"utilization\":\(utilization)"
                + (resets.map { ",\"resetsAt\":\(offset($0))" } ?? "") + "}"
        }
        func stream(_ entries: [String]) -> String {
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
                + entries.joined(separator: ",") + "}}}"
        }
        // Each window first at a lower use with one reset time, then higher with another or none.
        for later in [2 * 86_400, nil] as [Int?] {
            let reply =
                stream([
                    entry(WindowName.fiveHour, "0.1", resets: 3_600),
                    entry(WindowName.sevenDay, "0.4", resets: 3 * 86_400),
                    entry(WindowName.fable, "0.3", resets: 3 * 86_400),
                ]) + "\n"
                + stream([
                    entry(WindowName.fiveHour, "0.9", resets: later.map { _ in 7_200 }),
                    entry(WindowName.sevenDay, "0.95", resets: later),
                    entry(WindowName.fable, "0.9", resets: later),
                ])
            guard case .reading(let r) = ProbeReader.parse(reply, readAt: readAt) else {
                Issue.record("expected a reading")
                continue
            }
            let note = "later reset \(later.map { "\($0)" } ?? "none")"
            #expect(r.fiveHour?.usedPercent == 90, "\(note)")
            #expect(r.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_800_003_600), "\(note)")
            #expect(r.sevenDay?.usedPercent == 95, "\(note)")
            #expect(
                r.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000 + 3 * 86_400),
                "\(note)")
            #expect(r.fable?.usedPercent == 90, "\(note)")
            #expect(
                r.fable?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000 + 3 * 86_400),
                "\(note)")
        }
    }

    @Test func aWindowAPickReadsKeepsTheHighestUseOfOneReplyInEitherOrderUnlessItsWindowEnded() {
        func entry(_ name: String, _ utilization: String, resets: Int?) -> String {
            "\"\(name)\":{\"utilization\":\(utilization)"
                + (resets.map { ",\"resetsAt\":\(offset($0))" } ?? "") + "}"
        }
        func stream(_ entries: [String]) -> String {
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
                + entries.joined(separator: ",") + "}}}"
        }
        let names = [WindowName.fiveHour, WindowName.sevenDay, WindowName.fable, "monthly_extra"]
        let hour = Date(timeIntervalSince1970: 1_800_003_600)
        // The higher entry has no reset time, or one that passed a minute before the probe, so
        // the merge alone would take the lower entry, whose reset time is an hour out.
        for higherReset in [nil, -60] as [Int?] {
            let high = stream(names.map { entry($0, "0.95", resets: higherReset) })
            let low = stream(names.map { entry($0, "0.4", resets: 3_600) })
            let orders = [("higher first", high + "\n" + low), ("lower first", low + "\n" + high)]
            for (order, reply) in orders {
                let note = "\(order), higher reset \(higherReset.map { "\($0)" } ?? "none")"
                guard case .reading(let r) = ProbeReader.parse(reply, readAt: readAt) else {
                    Issue.record("expected a reading, \(note)")
                    continue
                }
                // A higher entry with no reset time counts; one whose window had ended before the
                // reply was read does not count toward the next window, in either order.
                let use: Double = higherReset == nil ? 95 : 40
                let kept = WindowReading(usedPercent: use, resetsAt: hour, readAt: readAt)
                #expect(r.fiveHour == kept, "\(note)")
                #expect(r.sevenDay == kept, "\(note)")
                #expect(r.fable?.usedPercent == use && r.fable?.resetsAt == hour, "\(note)")
                // A window no pick reads keeps the plain rule.
                #expect(r.windows["monthly_extra"]?.usedPercent == 40, "\(note)")
            }
        }
    }

    @Test func anEntryWhoseWindowHadEndedNeverCountsTowardALaterOrUnknownWindow() {
        func entry(_ name: String, _ utilization: String, resets: Int?) -> String {
            "\"\(name)\":{\"utilization\":\(utilization)"
                + (resets.map { ",\"resetsAt\":\(offset($0))" } ?? "") + "}"
        }
        func stream(_ entries: [String]) -> String {
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
                + entries.joined(separator: ",") + "}}}"
        }
        let names: [String] = [WindowName.fiveHour, WindowName.sevenDay, WindowName.fable]
        func length(_ name: String) -> Int { name == WindowName.fiveHour ? 5 * 3_600 : 7 * 86_400 }
        func window(_ reading: Reading, _ name: String) -> WindowReading? {
            guard name == WindowName.fable else { return reading.windows[name] }
            return reading.fable.map {
                WindowReading(
                    usedPercent: $0.usedPercent ?? -1, resetsAt: $0.resetsAt, readAt: readAt)
            }
        }
        // Each window ended a minute before the probe at 95 percent; the reply also names it with
        // no reset time at 50 percent, and the next window at 2 percent.
        let ended = stream(names.map { entry($0, "0.95", resets: -60) })
        // A window whose reset time is the reading time had ended too.
        let endedNow = stream(names.map { entry($0, "0.95", resets: 0) })
        let unknown = stream(names.map { entry($0, "0.5", resets: nil) })
        let next = stream(names.map { entry($0, "0.02", resets: length($0)) })
        let cases: [(lines: [String], use: Double, nextReset: Bool)] = [
            ([ended, next], 2, true), ([next, ended], 2, true),
            ([endedNow, next], 2, true), ([next, endedNow], 2, true),
            ([ended, unknown], 50, false), ([unknown, ended], 50, false),
            ([ended, unknown, next], 50, true), ([ended, next, unknown], 50, true),
            ([unknown, ended, next], 50, true), ([unknown, next, ended], 50, true),
            ([next, ended, unknown], 50, true), ([next, unknown, ended], 50, true),
        ]
        for (index, item) in cases.enumerated() {
            let reply = item.lines.joined(separator: "\n")
            guard case .reading(let r) = ProbeReader.parse(reply, readAt: readAt) else {
                Issue.record("expected a reading, case \(index)")
                continue
            }
            for name in names {
                let reset: Date? =
                    item.nextReset ? readAt.addingTimeInterval(Double(length(name))) : nil
                let expected = WindowReading(usedPercent: item.use, resetsAt: reset, readAt: readAt)
                #expect(window(r, name) == expected, "case \(index), \(name)")
            }
        }
        // So the next reply of the new window is stored as it is, not held at the ended window's
        // use until the new reset time.
        guard case .reading(let first) = ProbeReader.parse(ended + "\n" + next, readAt: readAt)
        else {
            Issue.record("expected a reading of the ended window and the next one")
            return
        }
        let later = readAt.addingTimeInterval(600)
        let again = stream(names.map { entry($0, "0.03", resets: length($0)) })
        guard case .reading(let second) = ProbeReader.parse(again, readAt: later) else {
            Issue.record("expected a reading of the next window")
            return
        }
        let stored = ReadingMerge.merge(
            stored: first, incoming: second, fableSettings: FableSettings(), now: later)
        for name in names { #expect(used(stored, name) == 3, "\(name)") }
    }

    @Test func aResetUpToThirtySecondsPastTheBoundFailsTheReading() {
        let slack = Int(ResetBounds.slack)
        for (name, length) in Self.windowLengths {
            #expect(parses(name, offset(length + slack)) != nil, "\(name) at the upper bound")
            #expect(parses(name, offset(-slack)) != nil, "\(name) at the lower bound")
            for past in 1...30 {
                #expect(parses(name, offset(length + slack + past)) == nil, "\(name) +\(past) s")
                #expect(parses(name, offset(-slack - past)) == nil, "\(name) -\(past) s")
            }
        }
    }

    // A reset time the probe accepts holds its window until it passes, so a fake one holds it for
    // at most one window length plus the slack.

    func used(_ reading: Reading, _ name: String) -> Double? {
        name == WindowName.fable ? reading.fable?.usedPercent : reading.windows[name]?.usedPercent
    }

    func withReset(_ reading: Reading, _ name: String, _ reset: Date) -> Reading {
        var out = reading
        if name == WindowName.fable {
            out.fable?.resetsAt = reset
        } else {
            out.windows[name]?.resetsAt = reset
        }
        return out
    }

    /// A probe reading of 5 percent at `now` whose window resets ten minutes later.
    func lower(_ name: String, at now: Date) -> Reading {
        let reset = now.addingTimeInterval(600)
        if name == WindowName.fable {
            return Reading(
                readAt: now,
                fable: FableReading(
                    source: ReadingSource.probe, usedPercent: 5, resetsAt: reset, readAt: now))
        }
        return Reading(
            readAt: now,
            windows: [name: WindowReading(usedPercent: 5, resetsAt: reset, readAt: now)])
    }

    @Test func aResetAtTheLatestTheProbeAcceptsHoldsTheWindowUntilItPasses() throws {
        let fable = FableSettings()
        for (name, length) in Self.windowLengths {
            let latest = length + Int(ResetBounds.slack)
            let stored = try #require(parses(name, offset(latest)), "\(name) at the latest reset")
            #expect(parses(name, offset(latest + 60)) == nil, "\(name) a minute later")
            let resets = readAt.addingTimeInterval(Double(latest))
            func merged(_ stored: Reading, at now: Date) -> Double? {
                used(
                    ReadingMerge.merge(
                        stored: stored, incoming: lower(name, at: now), fableSettings: fable,
                        now: now), name)
            }
            #expect(used(stored, name) == 50)
            #expect(merged(stored, at: readAt.addingTimeInterval(60)) == 50, "\(name) holds")
            #expect(merged(stored, at: resets.addingTimeInterval(-1)) == 50, "\(name) holds")
            #expect(merged(stored, at: resets) == 5, "\(name) is replaced once its reset passes")
            // A stored reset past the ceiling was never accepted by a probe and is not trusted.
            let ceiling = ResetBounds.storedCeiling(window: name, now: readAt)
            #expect(merged(withReset(stored, name, ceiling), at: readAt) == 50, "\(name) ceiling")
            #expect(
                merged(withReset(stored, name, ceiling.addingTimeInterval(1)), at: readAt) == 5,
                "\(name) past the ceiling")
        }
    }
}
