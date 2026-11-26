import Foundation
import Testing

@testable import Core

/// A probe's result reaches the account it probed, and what a finished probe or a new token's
/// first check found is kept when the status rebuild that records it does not save the state:
/// held by the history lock, cut off by the terminate signal, or stopped by a broken record.
extension TokenAccountsCLITests {
    /// The change time of the history lock file, which each command that opens it to take it
    /// stamps.
    func historyLockStamp(_ cli: CLIHome) -> timespec? {
        var info = stat()
        let file = cli.dataRoot.appendingPathComponent("locks/\(StatusBuilder.lockName)").path
        return stat(file, &info) == 0 ? info.st_ctimespec : nil
    }

    func holdHistoryLock(_ cli: CLIHome) throws -> FileLock {
        try #require(
            try NoFollowWriter(root: cli.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: StatusBuilder.lockName, wait: 60))
    }

    /// Has the next sign-in put a folder in place of `relative` under the data folder, after the
    /// checks before it, so the rebuild of the first check meets it. Returns how to undo it.
    func breakDuringSignIn(_ cli: CLIHome, _ relative: String) throws -> () throws -> Void {
        let path = cli.dataRoot.appendingPathComponent(relative)
        let aside = cli.home.appendingPathComponent("aside-" + path.lastPathComponent)
        try cli.fake(
            "during-setup-token.sh",
            """
            mv "\(path.path)" "\(aside.path)"
            mkdir "\(path.path)"

            """)
        return {
            try FileManager.default.removeItem(at: path)
            if FileManager.default.fileExists(atPath: aside.path) {
                try #require(rename(aside.path, path.path) == 0)
            }
        }
    }

    /// lab signed in, with a reading stored while the clock ran an hour ahead that a rebuild saw,
    /// and then a probe's rejection of its token; the next sign-in's token works.
    func labRejectedAheadOfTheClock(_ cli: CLIHome) throws {
        try addLab(cli)
        try loginLab(cli)
        let ahead = secondNow().addingTimeInterval(3600)
        try dateLabReading(cli, ahead)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        try #require(try #require(try labRejectionTime(cli)) >= ahead)
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
    }

    @Test(arguments: ["history lock held", "events record", "history lock broken"])
    func aNewTokensFirstCheckEndsTheOldRejectionWhenItsOwnRebuildSavedNoState(how: String)
        throws
    {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labRejectedAheadOfTheClock(cli)
        var undo: (() throws -> Void)?
        var held: FileLock?
        defer { held?.release() }
        switch how {
        case "history lock held": held = try holdHistoryLock(cli)
        case "events record": undo = try breakDuringSignIn(cli, "state/events.jsonl")
        default: undo = try breakDuringSignIn(cli, "locks/\(StatusBuilder.lockName)")
        }
        let skipped = logLines(cli, holding: "status rebuild skipped")
        let login = try cli.run(["login", "lab"])
        #expect(login.status == 0)
        #expect(String(decoding: login.stdout, as: UTF8.self).contains("First check: read"))
        if how == "history lock held" {
            #expect(logLines(cli, holding: "status rebuild skipped") == skipped + 1)
        }
        // The first check's rebuild saved no state, so the state still holds the old rejection.
        #expect(try recordedEntry(cli, "lab")?.probeError?.code == "login_rejected")
        held?.release()
        held = nil
        try undo?()
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try expectLabCompetesAgain(cli)
        #expect(try cli.run(["run", "lab", "--print-command"]).status == 0)
        try expectNoNewField(cli)
    }

    @Test func aRejectionAProbeRecordsAfterAKeptNewTokenCheckStillStands() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labRejectedAheadOfTheClock(cli)
        let undo = try breakDuringSignIn(cli, "state/events.jsonl")
        #expect(try cli.run(["login", "lab"]).status == 0)
        try undo()
        // The new token goes bad too, and the probe that finds it comes before any rebuild that
        // folds the kept check.
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        #expect(try recordedEntry(cli, "lab")?.probeError?.code == "login_rejected")
        try expectLabKeptOut(cli)
    }

    @Test func aRefreshEndedWhileItsRejectionWaitsForTheHistoryLockKeepsTheTokenOut() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // lab's reading is fresh, and its daily Fable probe answers with an auth error.
        try fableAnswers(cli, "auth_error.jsonl", capPercentOfWeekly: 100)
        try tune(cli) { $0.fable.probeTimeoutSeconds = 600 }
        var held: FileLock? = try holdHistoryLock(cli)
        defer { held?.release() }
        let taken = try #require(historyLockStamp(cli))
        let ends = probeEnds(cli, "lab")
        let refresh = try EndableCommand(cli, ["refresh", "--label", "lab"])
        // The Fable probe has ended, and the rebuild that records it waits for the history lock.
        try #require(
            pollUntil {
                probeEnds(cli, "lab") > ends
                    && historyLockStamp(cli).map {
                        $0.tv_sec != taken.tv_sec || $0.tv_nsec != taken.tv_nsec
                    } ?? false
            })
        #expect(!refresh.hasEnded)
        #expect(refresh.end() != nil)
        held?.release()
        held = nil
        // The launcher pick skips lab before any probe of it, and `run` refuses it.
        let probes = try tokenProbeRuns(cli, "lab")
        let lab = try labInPick(cli, ["--caller", "launcher"])
        #expect(lab.eligible == false && lab.reason == "login rejected")
        let run = try cli.run(["run", "lab", "--print-command"])
        #expect(run.status == 1)
        #expect(String(decoding: run.stderr, as: UTF8.self).contains(Messages.probeLoginRejected))
        #expect(try tokenProbeRuns(cli, "lab") == probes)
        // The Fable probe whose result the status did not record stays due: the next refresh
        // runs it.
        #expect(try labFableTried(cli) == nil)
        #expect(try tokenProbeRuns(cli, "lab", model: ProbeForm.fableModel) == 1)
        _ = try cli.run(["refresh", "--label", "lab"])
        #expect(try tokenProbeRuns(cli, "lab", model: ProbeForm.fableModel) == 2)
    }

    /// The change time of the token records' lock file, which each command that opens it to take
    /// it stamps.
    func recordsLockStamp(_ cli: CLIHome) -> timespec? {
        var info = stat()
        let file = cli.dataRoot.appendingPathComponent("locks/\(StatusBuilder.recordsLockName)")
        return stat(file.path, &info) == 0 ? info.st_ctimespec : nil
    }

    @Test func theTerminateSignalWaitsForTheRejectionARefreshIsKeeping() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // lab's reading is fresh, and its daily Fable probe answers with an auth error.
        try fableAnswers(cli, "auth_error.jsonl", capPercentOfWeekly: 100)
        try tune(cli) { $0.fable.probeTimeoutSeconds = 600 }
        let lock = try #require(
            try NoFollowWriter(root: cli.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: StatusBuilder.recordsLockName, wait: 60))
        var held: FileLock? = lock
        defer { held?.release() }
        let taken = try #require(recordsLockStamp(cli))
        // Started here rather than through EndableCommand, to send the signal without waiting.
        let refresh = Process()
        refresh.executableURL = cli.exe
        refresh.arguments = ["refresh", "--label", "lab"]
        refresh.environment = ["HOME": cli.home.path, "PATH": "/usr/bin:/bin"]
        refresh.standardInput = FileHandle.nullDevice
        refresh.standardOutput = FileHandle.nullDevice
        refresh.standardError = FileHandle.nullDevice
        try refresh.run()
        // The Fable probe has answered, and the write that keeps its rejection waits for the lock.
        try #require(
            pollUntil {
                recordsLockStamp(cli).map {
                    $0.tv_sec != taken.tv_sec || $0.tv_nsec != taken.tv_nsec
                } ?? false
            })
        refresh.terminate()
        held?.release()
        held = nil
        #expect(pollUntil { !refresh.isRunning })
        try expectLabKeptOut(cli)
    }

    /// How many probes of an account that is not a token account the fake `claude` has ended.
    func untokenedProbeEnds(_ cli: CLIHome) -> Int {
        cli.fakeRecord("spans.log").split(separator: "\n").filter {
            $0.hasPrefix("end ") && Int($0.dropFirst(4)) != nil
        }.count
    }

    /// A pick probes `main`, a login account whose probe answers from the fixture `mainProbe`,
    /// and waits on spare-a's held probe while `main` is renamed `primary` and a new token account
    /// `main` is added and signed in, whose first check answers `firstCheck`; then the pick ends.
    /// Returns the login's exit code.
    func renameAndReplaceMainWhileAPickProbes(
        _ cli: CLIHome, mainProbe: String, firstCheck: String
    ) throws -> Int32 {
        try addLab(cli, "spare-a")
        try cli.fake("probe-for-spare-a.jsonl", try probeText(cli, week: 350_000, five: 5_000))
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "spare-a"]).status == 0)
        try tune(cli) {
            $0.probe.timeoutSeconds = 600
            $0.picker.deadlineSeconds = 600
        }
        #expect(try cli.run(["refresh", "--label", "main"]).status == 0)
        for label in ["main", "spare-a"] { try ageReading(cli, label) }
        try cli.fakeProbe(mainProbe)
        try cli.fake("hold-spare-a", "")
        defer { try? cli.fake("go-spare-a", "") }
        let ended = untokenedProbeEnds(cli)
        let pick = try EndableCommand(cli, ["pick", "--json", "--caller", "launcher"])
        try #require(heldProbe(cli, "spare-a"))
        try #require(pollUntil { untokenedProbeEnds(cli) > ended })
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        try addLab(cli, "main")
        try cli.fake("probe-for-main.jsonl", firstCheck)
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        let login = try cli.run(["login", "main"]).status
        #expect(!pick.hasEnded)
        try cli.fake("go-spare-a", "")
        #expect(pick.wait() != nil)
        return login
    }

    @Test func aPicksProbeOfARenamedAccountLeavesTheNewAccountUnderItsLabelAlone() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        // The login account's probe answers with an auth error; the new token works.
        let working = try probeText(cli, week: 450_000, five: 15_000)
        #expect(
            try renameAndReplaceMainWhileAPickProbes(
                cli, mainProbe: "auth_error.jsonl", firstCheck: working) == 0)
        let error = try row(cli, "main")["error"] as? [String: Any]
        #expect(error?["code"] as? String != "login_rejected")
        let answer = try object(
            try cli.run(["pick", "--json", "--dry-run", "--caller", "launcher"]))
        let candidates = try #require(answer["candidates"] as? [[String: Any]])
        let main = try #require(candidates.first { $0["label"] as? String == "main" })
        #expect(main["reason"] as? String != "login rejected")
    }

    @Test func aPicksWorkingProbeOfARenamedAccountLeavesTheNewAccountsRejection() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        // The login account's probe works; the new token's first check is rejected.
        let rejected = try probeAnswer(cli, "auth_error.jsonl")
        #expect(
            try renameAndReplaceMainWhileAPickProbes(
                cli, mainProbe: "ok.jsonl", firstCheck: rejected) == 1)
        let error = try row(cli, "main")["error"] as? [String: Any]
        #expect(error?["code"] as? String == "login_rejected")
        let run = try cli.run(["run", "main", "--print-command"])
        #expect(run.status == 1)
        #expect(String(decoding: run.stderr, as: UTF8.self).contains(Messages.probeLoginRejected))
    }
}

/// A status rebuild of this process that stops once it has read the token records, holding the
/// history lock until it is let go, as a command's rebuild stalls there. Its thread is its own,
/// never the shared pool's.
final class StalledRebuild: @unchecked Sendable {
    private let stopped = DispatchSemaphore(value: 0)
    private let go = DispatchSemaphore(value: 0)
    private let ended = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false
    private var saved: Bool?

    init(_ cli: CLIHome) throws {
        let context = ToolContext(home: cli.home, ambient: [:])
        let thread = Thread { [self] in
            let result = try? StatusBuilder.rebuilt(
                context: context, observations: StatusObservations(), now: Date(), lockWait: nil,
                afterRecordsRead: {
                    stopped.signal()
                    _ = go.wait(timeout: .now() + 600)
                })
            lock.lock()
            saved = result?.savedState
            lock.unlock()
            ended.signal()
        }
        thread.start()
        try #require(stopped.wait(timeout: .now() + 300) == .success)
    }

    /// Lets the rebuild go on, once, and waits for it to end. Says whether it saved
    /// `state/current.json`, nil when it saved nothing or still runs after five minutes.
    @discardableResult
    func resume() -> Bool? {
        lock.lock()
        let first = !released
        released = true
        lock.unlock()
        if first {
            go.signal()
            guard ended.wait(timeout: .now() + 300) == .success else { return nil }
        }
        lock.lock()
        defer { lock.unlock() }
        return saved
    }
}

/// The two writes that keep a new token's check and a refresh's rejection go on while another
/// command's status rebuild stalls between its record steps.
extension TokenAccountsCLITests {
    @Test func aNewTokensFirstCheckIsKeptWhileAnotherCommandsRebuildStalls() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labRejectedAheadOfTheClock(cli)
        // That rebuild holds the history lock past the 30 seconds the check's own rebuild waits.
        let stalled = try StalledRebuild(cli)
        defer { stalled.resume() }
        let skipped = logLines(cli, holding: "status rebuild skipped: the history lock")
        let login = try cli.run(["login", "lab"])
        #expect(login.status == 0)
        #expect(String(decoding: login.stdout, as: UTF8.self).contains("First check: read"))
        #expect(logLines(cli, holding: "status rebuild skipped: the history lock") == skipped + 1)
        // The stalled rebuild read the records before the check, so it saves the old rejection
        // and leaves the kept check to the next rebuild.
        #expect(stalled.resume() == true)
        #expect(try recordedEntry(cli, "lab")?.probeError?.code == "login_rejected")
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try expectLabCompetesAgain(cli)
        #expect(try cli.run(["run", "lab", "--print-command"]).status == 0)
    }

    @Test func aRefreshKeepsItsRejectionWhileAnotherCommandsRebuildStalls() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // lab's reading is fresh, and its daily Fable probe answers with an auth error.
        try fableAnswers(cli, "auth_error.jsonl", capPercentOfWeekly: 100)
        try tune(cli) { $0.fable.probeTimeoutSeconds = 600 }
        let stalled = try StalledRebuild(cli)
        defer { stalled.resume() }
        let taken = try #require(historyLockStamp(cli))
        let ends = probeEnds(cli, "lab")
        let refresh = try EndableCommand(cli, ["refresh", "--label", "lab"])
        // The Fable probe has ended, and the rebuild that records it waits for the history lock.
        try #require(
            pollUntil {
                probeEnds(cli, "lab") > ends
                    && historyLockStamp(cli).map {
                        $0.tv_sec != taken.tv_sec || $0.tv_nsec != taken.tv_nsec
                    } ?? false
            })
        // The rejection is kept while the stalled rebuild still holds the history lock.
        #expect(try labRejectionRecorded(cli))
        #expect(stalled.resume() == true)
        #expect(refresh.wait() != nil)
        // The refresh's own rebuild records it once the stall ends, so the status shows it.
        let error = try row(cli, "lab")["error"] as? [String: Any]
        #expect(error?["code"] as? String == "login_rejected")
        try expectLabKeptOut(cli)
    }

    @Test func aFableRejectionWhoseRebuildsSavedNoStateStaysDue() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // lab's reading is fresh, and its daily Fable probe answers with an auth error.
        try fableAnswers(cli, "auth_error.jsonl", capPercentOfWeekly: 100)
        // Every rebuild of the refresh saves no `state/current.json`, and the refresh runs to
        // its end.
        let undo = try breakTheRecord(cli, "events record")
        _ = try cli.run(["refresh", "--label", "lab"])
        try undo()
        #expect(try labRejectionRecorded(cli))
        // The Fable probe whose rejection the status did not record is not counted as tried, so
        // the next refresh runs it again.
        #expect(try labFableTried(cli) == nil)
        #expect(try tokenProbeRuns(cli, "lab", model: ProbeForm.fableModel) == 1)
        _ = try cli.run(["refresh", "--label", "lab"])
        #expect(try tokenProbeRuns(cli, "lab", model: ProbeForm.fableModel) == 2)
    }
}
