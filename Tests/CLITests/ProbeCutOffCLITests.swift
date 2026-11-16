import Foundation
import Testing

@testable import Core

/// A command run as a child process that the test can end the way the menu ends a `refresh` past
/// its timeout: with the terminate signal the child runner sends.
final class EndableCommand: @unchecked Sendable {
    private let process = Process()

    init(_ cli: CLIHome, _ args: [String]) throws {
        process.executableURL = cli.exe
        process.arguments = args
        process.environment = ["HOME": cli.home.path, "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var hasEnded: Bool { !process.isRunning }

    /// The exit status once the command has ended, or nil when it still runs after five minutes.
    func wait() -> Int32? {
        var polls = 0
        while process.isRunning && polls < 6000 {
            usleep(50_000)
            polls += 1
        }
        return process.isRunning ? nil : process.terminationStatus
    }

    /// Ends the command as the menu does, and waits for it.
    func end() -> Int32? {
        process.terminate()
        return wait()
    }
}

/// What a probe found when a deadline or the menu cuts its command off: a Fable probe still running
/// when its pick answers is tried again by the next Fable pick or refresh, and a `refresh` that is
/// ended keeps what its finished probes found. The test forces each order by holding probes.
extension TokenAccountsCLITests {
    func tune(_ cli: CLIHome, _ change: (inout Config) -> Void) throws {
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        var config = try store.loadRequired()
        change(&config)
        try store.save(config)
    }

    /// When lab's last Fable probe was tried, as its stored reading records it.
    func labFableTried(_ cli: CLIHome) throws -> Date? {
        let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
        return try #require(try store.load(label: "lab")).fableProbedAt
    }

    /// The entry `state/current.json` keeps for `label`, read with no rebuild.
    func recordedEntry(_ cli: CLIHome, _ label: String) throws -> CurrentEntry? {
        let data = try NoFollowReader(root: cli.dataRoot).read(
            folders: Layout.stateFolders, name: "current.json")
        guard let data else { return nil }
        return try EventLog.decoder().decode(CurrentFile.self, from: data).accounts[label]
    }

    /// How many probes named `span` the fake `claude` has ended.
    func probeEnds(_ cli: CLIHome, _ span: String) -> Int {
        cli.fakeRecord("spans.log").split(separator: "\n").filter { $0 == "end \(span)" }.count
    }

    /// Polls `condition` for at most five minutes.
    func pollUntil(_ condition: () throws -> Bool) rethrows -> Bool {
        for _ in 0..<6000 {
            if try condition() { return true }
            usleep(50_000)
        }
        return try condition()
    }

    /// True once the fake `claude` has written the marker `name`, polled for five minutes.
    func fakeMarked(_ cli: CLIHome, _ name: String) -> Bool {
        let marker = cli.home.appendingPathComponent(".ab-fake/\(name)")
        return pollUntil { FileManager.default.fileExists(atPath: marker.path) }
    }

    /// How many lines of the tool's log hold `text`.
    func logLines(_ cli: CLIHome, holding text: String) -> Int {
        let log = cli.dataRoot.appendingPathComponent("logs/agent-balancer.log")
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
        return lines.filter { $0.contains(text) }.count
    }

    /// Puts a folder in place of the events record, so a status rebuild saves no
    /// `state/current.json`, or of the history lock, so no rebuild runs. Returns how to undo it.
    func breakTheRecord(_ cli: CLIHome, _ broken: String) throws -> () throws -> Void {
        let path =
            broken == "events record"
            ? cli.dataRoot.appendingPathComponent("state/events.jsonl")
            : cli.dataRoot.appendingPathComponent("locks/history.lock")
        let aside = cli.home.appendingPathComponent("aside-" + path.lastPathComponent)
        try #require(rename(path.path, aside.path) == 0)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        return {
            try FileManager.default.removeItem(at: path)
            try #require(rename(aside.path, path.path) == 0)
        }
    }

    @Test(arguments: ["refresh", "Fable pick"])
    func aFableProbeCutOffByAPicksDeadlineRunsAgainOnTheNextOne(next: String) throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        try fableAnswers(cli, "fable.jsonl", capPercentOfWeekly: 100)
        // Long enough for the held probe to begin, and no probe timeout ends it.
        try tune(cli) {
            $0.picker.deadlineSeconds = 2
            $0.fable.probeTimeoutSeconds = 600
        }
        try cli.fake("hold-lab", "")
        defer { try? cli.fake("go-lab", "") }
        let pick = [
            "pick", "--json", "--exclude", "main", "--model", "fable", "--caller", "launcher",
        ]
        let first = try cli.run(pick)
        // The pick answered on the fresh reading while its Fable probe, its only one, was held.
        #expect(heldProbe(cli, "lab"))
        #expect(try object(first)["label"] as? String == "lab")
        #expect(try tokenProbeRuns(cli, "lab", model: "fable") == 1)
        #expect(try labFableTried(cli) == nil)
        try cli.fake("go-lab", "")
        try tune(cli) { $0.picker.deadlineSeconds = Config().picker.deadlineSeconds }
        if next == "refresh" {
            #expect(try cli.run(["refresh", "--label", "lab"]).status == 0)
        } else {
            #expect(try cli.run(pick).status == 0)
        }
        #expect(try tokenProbeRuns(cli, "lab", model: "fable") == 2)
        #expect(try labFableTried(cli) != nil)
    }

    @Test func aRefreshThatIsEndedEarlyKeepsWhatItsFinishedProbesFound() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        let working = try probeText(cli, week: 380_000, five: 7_000)
        try addLab(cli, "spare-b")
        try cli.fake("probe-for-spare-b.jsonl", working)
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "spare-b"]).status == 0)
        // spare-b's last probe failed, so its row keeps check_failed until a probe of it works.
        try cli.fake("probe-for-spare-b.jsonl", try probeAnswer(cli, "no_event.jsonl"))
        #expect(try cli.run(["refresh", "--label", "spare-b", "--force"]).status == 1)
        #expect(try recordedEntry(cli, "spare-b")?.probeError?.code == "check_failed")
        try cli.fake("probe-for-spare-b.jsonl", working)
        // Old readings: lab's probe is rejected, spare-b's works, and spare-a's is held to the end.
        for label in ["lab", "spare-a", "spare-b"] { try ageReading(cli, label) }
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        try cli.fake("hold-spare-a", "")
        defer { try? cli.fake("go-spare-a", "") }
        let spareEnds = probeEnds(cli, "spare-a")
        let refresh = try EndableCommand(cli, ["refresh"])
        try #require(heldProbe(cli, "spare-a"))
        // The status holds what lab's and spare-b's probes found while the refresh still runs.
        try #require(
            try pollUntil {
                try labRejectionRecorded(cli)
                    && recordedEntry(cli, "spare-b").map { $0.probeError == nil } == true
            })
        #expect(probeEnds(cli, "spare-a") == spareEnds)
        #expect(!refresh.hasEnded)
        #expect(refresh.end() != nil)
        try cli.fake("go-spare-a", "")
        #expect(try labRejectionRecorded(cli))
        #expect(try recordedEntry(cli, "spare-b")?.probeError == nil)
        // The launcher pick skips lab before any probe, and `run` refuses it.
        let probes = try tokenProbeRuns(cli, "lab")
        let lab = try labInPick(cli, ["--caller", "launcher"])
        #expect(lab.eligible == false && lab.reason == "login rejected")
        let run = try cli.run(["run", "lab", "--print-command"])
        #expect(run.status == 1)
        #expect(String(decoding: run.stderr, as: UTF8.self).contains(Messages.probeLoginRejected))
        #expect(try tokenProbeRuns(cli, "lab") == probes)
    }

    @Test func aRefreshThatIsEndedDuringAFableProbeKeepsThatAccountsPlainProbe() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // lab's last probe failed, so its row keeps check_failed until a probe of it works.
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "no_event.jsonl"))
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        #expect(try recordedEntry(cli, "lab")?.probeError?.code == "check_failed")
        // An old reading and a Fable probe due: the plain probe works, and the Fable probe is held.
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 380_000, five: 7_000))
        try fableAnswers(cli, "fable.jsonl", capPercentOfWeekly: 100)
        try tune(cli) { $0.fable.probeTimeoutSeconds = 600 }
        try ageReading(cli, "lab")
        try cli.fake("hold-lab-\(ProbeForm.fableModel)", "")
        defer { try? cli.fake("go-lab-\(ProbeForm.fableModel)", "") }
        let refresh = try EndableCommand(cli, ["refresh", "--label", "lab"])
        try #require(fakeMarked(cli, "held-lab-\(ProbeForm.fableModel)"))
        let ends = probeEnds(cli, "lab")
        // The status holds lab's plain probe while its Fable probe still runs.
        try #require(
            try pollUntil { try recordedEntry(cli, "lab").map { $0.probeError == nil } == true })
        #expect(probeEnds(cli, "lab") == ends)
        #expect(!refresh.hasEnded)
        #expect(refresh.end() != nil)
        try cli.fake("go-lab-\(ProbeForm.fableModel)", "")
        #expect(try recordedEntry(cli, "lab")?.probeError == nil)
        // The Fable probe that the end cut off is not counted as tried.
        #expect(try labFableTried(cli) == nil)
    }

    @Test(arguments: ["events record", "history lock"])
    func aRefreshsLastRebuildRecordsAResultItsOwnRebuildDidNotSave(broken: String) throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        #expect(try cli.run(["refresh", "--label", "main"]).status == 0)
        // Old readings: lab's probe is rejected, and spare-a's is held to the end.
        for label in ["lab", "spare-a"] { try ageReading(cli, label) }
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        try cli.fake("hold-lab", "")
        defer { try? cli.fake("go-lab", "") }
        try cli.fake("hold-spare-a", "")
        defer { try? cli.fake("go-spare-a", "") }
        let refresh = try EndableCommand(cli, ["refresh"])
        try #require(heldProbe(cli, "lab"))
        try #require(heldProbe(cli, "spare-a"))
        // lab's probe ends while the rebuild that records it cannot save it.
        let failure = broken == "events record" ? "events step failed" : "status rebuild failed"
        let failures = logLines(cli, holding: failure)
        let undo = try breakTheRecord(cli, broken)
        try cli.fake("go-lab", "")
        try #require(pollUntil { logLines(cli, holding: failure) > failures })
        try undo()
        #expect(try recordedEntry(cli, "lab")?.probeError == nil)
        // The refresh's last rebuild records lab's rejection.
        try cli.fake("go-spare-a", "")
        #expect(refresh.wait() == 1)
        #expect(try recordedEntry(cli, "lab")?.probeError?.code == "login_rejected")
        let probes = try tokenProbeRuns(cli, "lab")
        let lab = try labInPick(cli, ["--caller", "launcher", "--exclude", "spare-a"])
        #expect(lab.eligible == false && lab.reason == "login rejected")
        #expect(try cli.run(["run", "lab", "--print-command"]).status == 1)
        #expect(try tokenProbeRuns(cli, "lab") == probes)
    }

    @Test func aRefreshsLastRebuildLeavesAResultItRecordedToWhatCameAfter() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        #expect(try cli.run(["refresh", "--label", "main"]).status == 0)
        // Old readings that the status sees, so a later probe stores a newer one: lab's probe is
        // rejected, and spare-a's is held.
        for label in ["lab", "spare-a"] { try ageReading(cli, label) }
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        try cli.fake("hold-spare-a", "")
        defer { try? cli.fake("go-spare-a", "") }
        let spareEnds = probeEnds(cli, "spare-a")
        let first = try EndableCommand(cli, ["refresh"])
        try #require(heldProbe(cli, "spare-a"))
        try #require(try pollUntil { try labRejectionRecorded(cli) })
        try #require(probeEnds(cli, "spare-a") == spareEnds)
        // Another refresh probes lab again; its probe works and ends the rejection.
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        #expect(try cli.run(["refresh", "--label", "lab"]).status == 0)
        #expect(try labRejectionRecorded(cli) == false)
        // The first refresh's last rebuild does not record lab's older rejection again.
        try cli.fake("go-spare-a", "")
        #expect(first.wait() == 1)
        #expect(try labRejectionRecorded(cli) == false)
        let lab = try labInPick(cli, ["--caller", "launcher", "--exclude", "spare-a"])
        #expect(lab.eligible == true && lab.picked == "lab")
    }
}
