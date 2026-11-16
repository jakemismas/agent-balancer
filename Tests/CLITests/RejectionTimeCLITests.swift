import Foundation
import Testing

@testable import Core

/// The routes by which an older reading used to end a newer probe rejection of a token: a clock
/// set back inside one command, a clock set back before a rejection with no usable reading, and a
/// reading file another process rewrites. Each is forced with chosen times and held probes, never
/// with sleeps; the rejection stands and the next `pick` and `run` keep the token out, until a
/// working probe stores a reading in a later second.
extension TokenAccountsCLITests {
    /// A probe of lab at `time`, as the clock reads then, through the fake `claude`. Its status
    /// rebuild is the caller's.
    func probeLab(_ cli: CLIHome, at time: Date) throws -> AccountRefresh {
        let context = ToolContext(home: cli.home, ambient: [:])
        let config = try ConfigStore(context: context).loadRequired()
        var refresher = Refresher(context: context, config: config)
        refresher.clock = { time }
        return refresher.refresh(
            account: try #require(config.account("lab")), force: true, fable: .none)
    }

    /// A status rebuild at `time` that folds what `results` found.
    func rebuild(_ cli: CLIHome, _ results: [AccountRefresh], at time: Date) throws {
        var observations = StatusObservations()
        observations.add(results)
        try StatusBuilder.rebuild(
            context: ToolContext(home: cli.home, ambient: [:]), observations: observations,
            now: time)
    }

    func storedLabReading(_ cli: CLIHome) throws -> Reading {
        let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
        return try #require(try store.load(label: "lab"))
    }

    /// Saves lab's stored reading dated `time`, as another process that runs as the user could.
    func dateLabReading(_ cli: CLIHome, _ time: Date) throws {
        var reading = try storedLabReading(cli)
        reading.readAt = time
        try ReadingStore(context: ToolContext(home: cli.home, ambient: [:])).save(
            reading, label: "lab")
    }

    func secondNow() -> Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)) }

    /// Keeps lab's stored reading from the next command as `form` says, and returns how to undo it.
    func setLabReadingAside(_ cli: CLIHome, _ form: ReadingGone) throws -> () throws -> Void {
        let readings = cli.dataRoot.appendingPathComponent("state/readings")
        let file = readings.appendingPathComponent("lab.json")
        let moved = form == .folderMoveAway ? readings : file
        let aside = cli.home.appendingPathComponent("away-" + moved.lastPathComponent)
        try #require(rename(moved.path, aside.path) == 0)
        if form == .garbage {
            try #require(
                FileManager.default.createFile(
                    atPath: file.path, contents: Data("not a reading\n".utf8),
                    attributes: [.posixPermissions: 0o600]))
        }
        return { try #require(rename(aside.path, moved.path) == 0) }
    }

    /// lab's rejection stands; the launcher and the typed pick skip lab before any probe, and
    /// `run` refuses it.
    func expectLabKeptOut(_ cli: CLIHome) throws {
        #expect(try labRejectionRecorded(cli))
        let probes = try tokenProbeRuns(cli, "lab")
        for flags in [["--caller", "launcher"], []] {
            let lab = try labInPick(cli, flags)
            #expect(lab.eligible == false && lab.reason == "login rejected", "\(flags)")
            #expect(lab.picked == nil, "\(flags)")
        }
        // The picks saved the settings verdict that `run` relies on.
        let run = try cli.run(["run", "lab", "--print-command"])
        #expect(run.status == 1)
        #expect(String(decoding: run.stderr, as: UTF8.self).contains(Messages.probeLoginRejected))
        #expect(try tokenProbeRuns(cli, "lab") == probes)
    }

    func expectLabCompetesAgain(_ cli: CLIHome) throws {
        #expect(try labRejectionRecorded(cli) == false)
        let lab = try labInPick(cli, ["--caller", "launcher"])
        #expect(lab.eligible == true && lab.picked == "lab")
    }

    /// lab's entry in `state/current.json` and its durable rejection record hold only the fields
    /// this version always wrote.
    func expectNoNewField(_ cli: CLIHome) throws {
        let reader = NoFollowReader(root: cli.dataRoot)
        func object(_ name: String) throws -> [String: Any] {
            let data = try #require(try reader.read(folders: Layout.stateFolders, name: name))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let entries = try #require(try object("current.json")["accounts"] as? [String: Any])
        let entry = try #require(entries["lab"] as? [String: Any])
        let fields: Set<String> = [
            "accountKey", "state", "code", "since", "limitedWindow", "limitedSince",
            "limitedUntil", "lastReadingAt", "authError", "probeError", "planTier",
            "loginExpiresAt", "endedByPlan", "expiringNotified", "historyAt", "historySignature",
            "possibleDuplicateOf", "signInCheck", "emailDigest",
        ]
        #expect(Set(entry.keys).isSubset(of: fields))
        // The durable record: its schema version and its records by label, as this version wrote.
        let durable = try object(StatusBuilder.rejectionsName)
        #expect(durable.count == 2 && durable["schemaVersion"] != nil)
        for case let saved as [String: Any] in durable.values {
            for case let record as [String: Any] in saved.values {
                #expect(Set(record.keys) == ["accountKey", "at"])
            }
        }
    }

    @Test func aClockSetBackInsideOneCommandLetsNoOlderWorkingProbeEndALaterRejection() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // lab's reading is an hour old, and a rebuild sees it.
        try ageReading(cli, "lab")
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        let t = secondNow()
        let working = try probeText(cli, week: 450_000, five: 15_000)
        try cli.fake("probe-for-lab.jsonl", working)
        // A command's probe works at t, and its rebuild comes late, as a waiting pick's does.
        let older = try probeLab(cli, at: t)
        guard case .probed(let olderReading) = older.status else {
            Issue.record("expected a working probe, got \(older.status)")
            return
        }
        #expect(olderReading.readAt == t)
        // The clock steps back two minutes. A second command's probe works, and it rebuilds.
        let second = try probeLab(cli, at: t.addingTimeInterval(-115))
        try rebuild(cli, [second], at: t.addingTimeInterval(-115))
        #expect(try storedLabReading(cli).readAt == t.addingTimeInterval(-115))
        // The token goes bad. A third command's probe is rejected, and its rebuild lands first.
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        let rejected = try probeLab(cli, at: t.addingTimeInterval(-110))
        try rebuild(cli, [rejected], at: t.addingTimeInterval(-110))
        try #require(try labRejectionRecorded(cli))
        // The menu's rebuild, then the first command's late one, which folds its older probe.
        try rebuild(cli, [], at: t.addingTimeInterval(-108))
        try rebuild(cli, [older], at: t.addingTimeInterval(-105))
        try expectLabKeptOut(cli)
        try expectNoNewField(cli)
        // A working probe that stores a reading in a later second ends the rejection.
        try cli.fake("probe-for-lab.jsonl", working)
        let back = try probeLab(cli, at: t.addingTimeInterval(-100))
        try rebuild(cli, [back], at: t.addingTimeInterval(-100))
        try expectLabCompetesAgain(cli)
    }

    @Test(arguments: ReadingGone.allCases)
    func aClockSetBackBeforeARejectionWithNoUsableReadingLeavesItStanding(form: ReadingGone)
        throws
    {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // A reading stored before the clock was set back reads 30 s ahead, and a rebuild sees it.
        let ahead = secondNow().addingTimeInterval(30)
        try dateLabReading(cli, ahead)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        // A forced refresh's probe is held while the reading is set aside, until it is rejected.
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        try cli.fake("hold-lab", "")
        defer { try? cli.fake("go-lab", "") }
        let refresh = try EndableCommand(cli, ["refresh", "--label", "lab", "--force"])
        try #require(heldProbe(cli, "lab"))
        let putBack = try setLabReadingAside(cli, form)
        try cli.fake("go-lab", "")
        #expect(refresh.wait() == 1)
        try putBack()
        #expect(try storedLabReading(cli).readAt == ahead)
        // The rejection is dated no earlier than the reading the status had seen.
        let rejectedAt = try #require(try labRejectionTime(cli))
        #expect(rejectedAt >= ahead)
        // The menu's rebuild reads that reading again, and the rejection stands.
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try expectLabKeptOut(cli)
        try expectNoNewField(cli)
        // A working probe that stores a reading in a later second ends it.
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        let back = try probeLab(cli, at: rejectedAt.addingTimeInterval(1))
        try rebuild(cli, [back], at: rejectedAt.addingTimeInterval(1))
        try expectLabCompetesAgain(cli)
    }

    @Test func anOlderCopyInPlaceWhileARejectionIsRecordedCannotEndItOnceTheNewerIsBack() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // The newer reading, a minute old, is the latest the status has seen.
        let now = secondNow()
        try dateLabReading(cli, now.addingTimeInterval(-60))
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        let newer = try storedLabReading(cli)
        // An hour-old copy is in place while a rejection is recorded, then the newer one is back.
        try dateLabReading(cli, now.addingTimeInterval(-3600))
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        #expect(try labRejectionTime(cli) == newer.readAt)
        try ReadingStore(context: ToolContext(home: cli.home, ambient: [:])).save(
            newer, label: "lab")
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try expectLabKeptOut(cli)
        try expectNoNewField(cli)
        // A refresh probes lab again; the probe works with a reading in a later second.
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        #expect(try cli.run(["refresh", "--label", "lab"]).status == 0)
        try expectLabCompetesAgain(cli)
    }

    @Test func anOlderCopyPutBackAfterTheReadingWasGoneCannotEndARejection() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // lab's reading is an hour old, and a rebuild sees it.
        try ageReading(cli, "lab")
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        // A command's probe works and stores a newer reading, and its rebuild comes late.
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        let worked = try probeLab(cli, at: secondNow().addingTimeInterval(-30))
        let newer = try storedLabReading(cli)
        // The reading is gone while a forced refresh records the token's rejection.
        let putBack = try setLabReadingAside(cli, .moveAway)
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        let rejectedAt = try #require(try labRejectionTime(cli))
        #expect(rejectedAt >= newer.readAt)
        // An older copy is put back and the menu's rebuild reads it; the rejection keeps its time.
        try putBack()
        var older = newer
        older.readAt = newer.readAt.addingTimeInterval(-5)
        let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
        try store.save(older, label: "lab")
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        #expect(try labRejectionTime(cli) == rejectedAt)
        // The working command's late rebuild folds its probe, and then the newer reading is back.
        try rebuild(cli, [worked], at: Date())
        #expect(try labRejectionRecorded(cli))
        try store.save(newer, label: "lab")
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try expectLabKeptOut(cli)
        try expectNoNewField(cli)
        // A working probe that stores a reading in a later second ends it.
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        let back = try probeLab(cli, at: rejectedAt.addingTimeInterval(1))
        try rebuild(cli, [back], at: rejectedAt.addingTimeInterval(1))
        try expectLabCompetesAgain(cli)
    }

    @Test func aLoginRecordsItsNewTokensFirstCheckBeforeItLetsTheProbeLockGo() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        try #require(try labRejectionRecorded(cli))
        // The test holds the history lock, so every status rebuild waits for it.
        let writer = NoFollowWriter(root: cli.dataRoot)
        let history = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: StatusBuilder.lockName, wait: 5))
        var holding = true
        defer { if holding { history.release() } }
        let file = cli.dataRoot.appendingPathComponent("locks/\(StatusBuilder.lockName)").path
        // Taking a lock sets its file's mode, which stamps the file's change time.
        func stamp() -> timespec? {
            var info = stat()
            return stat(file, &info) == 0 ? info.st_ctimespec : nil
        }
        let taken = try #require(stamp())
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        let login = try EndableCommand(cli, ["login", "lab"])
        // The new token's first check came to its status rebuild, and lab's probe lock is held.
        try #require(
            pollUntil {
                stamp().map { $0.tv_sec != taken.tv_sec || $0.tv_nsec != taken.tv_nsec } ?? false
            })
        let probeLock = try writer.acquireLock(
            folders: Layout.locksFolders, name: Layout.lockName("lab"), wait: 0)
        #expect(probeLock == nil)
        probeLock?.release()
        history.release()
        holding = false
        #expect(login.wait() == 0)
        try expectLabCompetesAgain(cli)
    }

    @Test(arguments: [false, true])
    func aRejectionDatedAheadOfTheClockEndsOnceANewTokensFirstCheckWorks(statusFileGone: Bool)
        throws
    {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // lab's reading was stored while the clock ran an hour ahead, and a rebuild sees it.
        let ahead = secondNow().addingTimeInterval(3600)
        try dateLabReading(cli, ahead)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        // With the clock right again, the token goes bad and a forced refresh records it.
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        #expect(try #require(try labRejectionTime(cli)) >= ahead)
        // A probe of the same token that works stores an older reading, so the rejection stands.
        let working = try probeText(cli, week: 450_000, five: 15_000)
        try cli.fake("probe-for-lab.jsonl", working)
        #expect(try cli.run(["refresh", "--label", "lab"]).status == 0)
        try expectLabKeptOut(cli)
        // So does a new token whose first check is rejected.
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 1)
        try expectLabKeptOut(cli)
        if statusFileGone {
            // The durable record alone holds the rejection.
            try FileManager.default.removeItem(
                at: cli.dataRoot.appendingPathComponent("state/current.json"))
            #expect(try labRejectionRecorded(cli))
        }
        // A new token whose first check works ends it: the rejection was of a token now gone.
        try cli.fake("probe-for-lab.jsonl", working)
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        try expectLabCompetesAgain(cli)
        #expect(try cli.run(["run", "lab", "--print-command"]).status == 0)
        try expectNoNewField(cli)
    }
}
