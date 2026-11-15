import Core
import Foundation
import Testing

@testable import Core

/// `refresh` checks the sign-in of each login and folder account every time it runs, and probes
/// again an account whose last probe found its sign-in rejected, so a sign-in that is back clears
/// `login_rejected` while the readings are still fresh. No other account is probed early, and a
/// recorded plan is never changed.
extension FolderAccountsCLITests {
    /// Stages both sign-ins: the login account `main` in the default folder and the folder account
    /// `spare` in its own folder.
    func stageBothSignIns(_ cli: CLIHome, loggedIn: Bool, tier: String = "max_20x") throws {
        try cli.fake(
            "auth-default.json",
            #"{"loggedIn":\#(loggedIn),"email":"main@example.com","planTier":"\#(tier)"}"#)
        try cli.fake(
            "auth.json",
            #"{"loggedIn":\#(loggedIn),"email":"\#(Self.email)","planTier":"\#(tier)","configDirectory":"\#(try folderPath(cli))"}"#
        )
        try cli.fake("auth.exit", "0")
    }

    /// How many probes the fake `claude` has run.
    func probeRuns(_ cli: CLIHome) -> Int {
        cli.fakeRecord("args.log").split(separator: "\n").filter { $0.hasPrefix("-p ") }.count
    }

    /// A home whose login account `main` and linked folder account `spare` are both signed in,
    /// each with a recorded plan and a fresh reading from one plain `refresh`.
    func freshPair() throws -> CLIHome {
        let cli = try setUp()
        try linked(cli)
        try stageBothSignIns(cli, loggedIn: true)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli) == 2)
        return cli
    }

    /// Dates the stored reading of `label` two minutes back, still fresh, so a probe after a
    /// rejection stores a newer one than the status saw with it.
    func ageFreshReading(_ cli: CLIHome, _ label: String) throws {
        let store = ReadingStore(context: context(cli))
        var reading = try #require(try store.load(label: label))
        reading.readAt = Date().addingTimeInterval(-120)
        try store.save(reading, label: label)
    }

    func errorCode(_ row: [String: Any]) -> String? {
        (row["error"] as? [String: Any])?["code"] as? String
    }

    /// `events --json`, after `cursor` when one is given.
    func eventsJSON(_ cli: CLIHome, after cursor: Int? = nil) throws -> [String: Any] {
        let out = try cli.run(["events", "--json"] + (cursor.map { ["--after", "\($0)"] } ?? []))
        #expect(out.status == 0)
        return try json(out)
    }

    /// The type and code of each event of `label`, oldest first.
    func eventTrail(_ document: [String: Any], _ label: String) throws -> [[String?]] {
        let list = try #require(document["events"] as? [[String: Any]])
        return list.filter { $0["label"] as? String == label }
            .map { [$0["type"] as? String, $0["code"] as? String] }
    }

    @Test func refreshClearsACheckRejectionOfALoginAndAFolderAccountSignedBackIn() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try stageBothSignIns(cli, loggedIn: false)
        #expect(try cli.run(["status", "--json"]).status == 0)
        for label in ["main", "spare"] {
            #expect(errorCode(try row(cli, label)) == "login_rejected", "\(label)")
        }

        // Signed back in. The readings are fresh, so only the sign-in checks can clear it.
        try stageBothSignIns(cli, loggedIn: true)
        let probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli) == probes)
        let events = try eventsJSON(cli)
        for label in ["main", "spare"] {
            let trail = try eventTrail(events, label)
            #expect(
                Array(trail.suffix(2)) == [["error", "login_rejected"], ["recovered", nil]],
                "\(label)")
        }
        let cursor = try #require(events["cursor"] as? Int)
        #expect((try eventsJSON(cli, after: cursor)["events"] as? [Any])?.isEmpty == true)
        for label in ["main", "spare"] {
            #expect(try row(cli, label)["error"] is NSNull, "\(label)")
        }
    }

    @Test func refreshProbesAgainOnlyTheAccountWhoseLastProbeFoundItsSignInRejected() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        // A probe finds the sign-in rejected while the stored reading is still fresh.
        try ageFreshReading(cli, "spare")
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 1)
        #expect(errorCode(try statusRow(cli)) == "login_rejected")

        // The sign-in is fixed. A plain refresh probes `spare` again, and no other account.
        try cli.fakeProbe("ok.jsonl")
        let probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli) == probes + 1)
        #expect(try statusRow(cli)["error"] is NSNull)
        let trail = try eventTrail(try eventsJSON(cli), "spare")
        #expect(Array(trail.suffix(2)) == [["error", "login_rejected"], ["recovered", nil]])
    }

    @Test func refreshProbesAgainALoginAccountWhoseLastProbeFoundItsSignInRejected() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try ageFreshReading(cli, "main")
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "main", "--force"]).status == 1)
        #expect(errorCode(try row(cli, "main")) == "login_rejected")
        try cli.fakeProbe("ok.jsonl")
        let probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli) == probes + 1)
        #expect(try row(cli, "main")["error"] is NSNull)
    }

    @Test func refreshKeepsTheFreshnessRuleOnceAProbeThatWorkedStoredANewerReading() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        let store = ReadingStore(context: context(cli))
        var reading = try #require(try store.load(label: "spare"))
        reading.readAt = Date().addingTimeInterval(-120)
        try store.save(reading, label: "spare")
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 1)
        #expect(errorCode(try statusRow(cli)) == "login_rejected")

        // Another command's probe worked and stored a newer reading before that command rebuilt
        // the status. The newer reading is fresh, so this refresh starts no probe.
        reading.readAt = Date().addingTimeInterval(-60)
        try store.save(reading, label: "spare")
        try cli.fakeProbe("ok.jsonl")
        let probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli) == probes)
    }

    @Test func refreshOverFreshReadingsStartsNoProbeAndStillChecksEachSignIn() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        func lines(_ name: String) -> [String] {
            cli.fakeRecord(name).split(separator: "\n").map(String.init)
        }
        let probes = probeRuns(cli)
        let calls = lines("args.log").count
        let folders = lines("config-dirs.log").count
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli) == probes)
        let newCalls = lines("args.log").dropFirst(calls)
        #expect(newCalls.count == 2, "\(newCalls)")
        #expect(newCalls.allSatisfy { $0.hasPrefix("auth status") }, "\(newCalls)")
        // One check in the default folder for `main`, one in the folder of `spare`.
        let checked = Set(lines("config-dirs.log").dropFirst(folders))
        #expect(checked == ["unset", try folderPath(cli)])
    }

    @Test func refreshKeepsARecordedPlanAndReportsAChangedOneAsStatusDoes() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try stageBothSignIns(cli, loggedIn: true, tier: "pro")
        #expect(try cli.run(["refresh"]).status == 0)
        var reported: [String: [String: String]] = [:]
        for label in ["main", "spare"] {
            let error = try #require(try row(cli, label)["error"] as? [String: String], "\(label)")
            #expect(error["code"] == "plan_changed", "\(label)")
            reported[label] = error
        }
        let config = try ConfigStore(context: context(cli)).loadRequired()
        #expect(config.accounts.map(\.expectedPlanTier) == ["max_20x", "max_20x"])

        // `status` reports the same change in the same words.
        #expect(try cli.run(["status", "--json"]).status == 0)
        for label in ["main", "spare"] {
            let error = try row(cli, label)["error"] as? [String: String]
            #expect(error == reported[label], "\(label)")
        }
    }

    @Test func refreshRecordsTheExpectedPlanOfASignedInLoginAccount() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try stageBothSignIns(cli, loggedIn: true)
        let store = ConfigStore(context: context(cli))
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "main" })
        config.accounts[index].expectedPlanTier = nil
        try store.save(config)
        #expect(try cli.run(["refresh", "--label", "main"]).status == 0)
        #expect(try store.loadRequired().account("main")?.expectedPlanTier == "max_20x")
    }

    @Test func refreshPlacesAgainTheChecksACurrentFileWithoutDigestsLost() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        #expect(try cli.run(["status", "--json"]).status == 0)
        #expect(try statusRow(cli)["signInCheck"] as? String == "signed_in")

        // `state/current.json` as a writer from before the email-bound check left it.
        var root = try #require(
            try JSONSerialization.jsonObject(with: Data(cli.read("state/current.json").utf8))
                as? [String: Any])
        var entries = try #require(root["accounts"] as? [String: Any])
        for (label, value) in entries {
            var entry = try #require(value as? [String: Any], "\(label)")
            #expect(entry.removeValue(forKey: "emailDigest") != nil, "\(label)")
            entries[label] = entry
        }
        root["accounts"] = entries
        try NoFollowWriter(root: cli.dataRoot).put(
            try JSONSerialization.data(withJSONObject: root), folders: Layout.stateFolders,
            name: "current.json")

        // The next rebuild drops the checks that file carried.
        for label in ["main", "spare"] {
            #expect(try row(cli, label)["planTier"] is NSNull, "\(label)")
        }
        #expect(try statusRow(cli)["signInCheck"] is NSNull)

        // One refresh over fresh readings places a check of each again, with no probe.
        let probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli) == probes)
        for label in ["main", "spare"] {
            #expect(try row(cli, label)["planTier"] as? String == "max_20x", "\(label)")
        }
        #expect(try statusRow(cli)["signInCheck"] as? String == "signed_in")
    }

    @Test func refreshKeepsTheFreshnessRuleAfterAProbeErrorThatIsNoRejection() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try cli.fakeProbe("no_event.jsonl")
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 1)
        #expect(errorCode(try statusRow(cli)) != "login_rejected")
        try cli.fakeProbe("ok.jsonl")
        let probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli) == probes)
    }

    @Test func refreshKeepsTheFreshnessRuleWhenTheRejectionRecordsNoReading() throws {
        let cli = try freshPair()
        defer { cli.cleanup() }
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 1)
        #expect(errorCode(try statusRow(cli)) == "login_rejected")

        // The rejection as a rebuild that saw no stored reading records it: the fresh reading
        // stored now is newer than any the status saw, so only a probe that worked stored it.
        var root = try #require(
            try JSONSerialization.jsonObject(with: Data(cli.read("state/current.json").utf8))
                as? [String: Any])
        var entries = try #require(root["accounts"] as? [String: Any])
        var entry = try #require(entries["spare"] as? [String: Any])
        #expect(entry.removeValue(forKey: "lastReadingAt") != nil)
        entries["spare"] = entry
        root["accounts"] = entries
        try NoFollowWriter(root: cli.dataRoot).put(
            try JSONSerialization.data(withJSONObject: root), folders: Layout.stateFolders,
            name: "current.json")
        let config = try ConfigStore(context: context(cli)).loadRequired()
        let spare = try #require(config.account("spare"))
        #expect(StatusBuilder.probeFoundSignInRejected(context: context(cli), account: spare))

        try cli.fakeProbe("ok.jsonl")
        let probes = probeRuns(cli)
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli) == probes)
    }
}
