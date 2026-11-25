import Foundation
import Testing

@testable import Core

/// Session records of the default folder, and the launch file upkeep that reads them.
@Suite struct SessionsAndUpkeepTests {
    let leaseId = "l-0a0b0c0d"

    func fileURL(_ t: TestHome, _ label: String, _ id: String) throws -> URL {
        try LaunchFiles.fileURL(context: t.context, label: label, leaseId: id)
    }

    func write(_ text: String, to url: URL, mode: Int = 0o600, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: mode, .modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path)
    }

    func entry(_ t: TestHome, pid: Int, id: String, jobId: String? = nil, name: String = "w") throws
    {
        var object: [String: Any] = [
            "pid": pid, "sessionId": id, "kind": "interactive", "name": name,
        ]
        if let jobId { object["jobId"] = jobId }
        let data = try JSONSerialization.data(withJSONObject: object)
        try write(
            String(decoding: data, as: UTF8.self),
            to: t.home.appendingPathComponent(".claude/sessions/\(pid).json"))
    }

    func job(_ t: TestHome, folder: String, id: String, naming url: URL?, state: String = "running")
        throws
    {
        var object: [String: Any] = ["sessionId": id, "state": state, "name": "job"]
        if let url { object["respawnFlags"] = ["--bg", "--settings", url.path] }
        let data = try JSONSerialization.data(withJSONObject: object)
        try write(
            String(decoding: data, as: UTF8.self),
            to: t.home.appendingPathComponent(".claude/jobs/\(folder)/state.json"))
    }

    // MARK: Reader

    @Test func aMissingFolderIsAnEmptyCleanRead() throws {
        let t = try TestHome()
        #expect(SessionsReader.read(context: t.context) == .empty)
    }

    @Test func aRecordWithoutAnIdOrPidStillNamesItsLaunchFile() throws {
        let t = try TestHome()
        let url = try fileURL(t, "pool-a", leaseId)
        try write(
            "{\"kind\":\"background\",\"args\":[\"--settings\",\"\(url.path)\"]}",
            to: t.home.appendingPathComponent(".claude/sessions/bg.json"))
        let snapshot = SessionsReader.read(context: t.context)
        #expect(snapshot.live.isEmpty)
        #expect(snapshot.named == [LaunchRef(label: "pool-a", leaseId: leaseId)])
    }

    @Test func aNamedPipeInTheRecordFoldersDoesNotBlockTheRead() throws {
        let t = try TestHome()
        let sessions = t.home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        #expect(mkfifo(sessions.appendingPathComponent("pipe.json").path, 0o600) == 0)
        let job = t.home.appendingPathComponent(".claude/jobs/j1")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        #expect(mkfifo(job.appendingPathComponent("state.json").path, 0o600) == 0)
        let snapshot = SessionsReader.read(context: t.context)
        #expect(!snapshot.clean && snapshot.live.isEmpty)
    }

    @Test func twoSessionsWithOneLaunchFileBetweenThemCountEachById() throws {
        let t = try TestHome()
        let url = try fileURL(t, "pool-a", leaseId)
        try entry(t, pid: 101, id: "aaaaaaaa-1111", jobId: "j1", name: "one")
        try entry(t, pid: 102, id: "bbbbbbbb-2222", jobId: "j2", name: "two")
        try job(t, folder: "j1", id: "aaaaaaaa-1111", naming: url)
        try job(t, folder: "j2", id: "bbbbbbbb-2222", naming: url)
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        #expect(snapshot.clean)
        #expect(snapshot.live.map(\.id).sorted() == ["aaaaaaaa-1111", "bbbbbbbb-2222"])
        #expect(
            snapshot.live.allSatisfy { $0.refs == [LaunchRef(label: "pool-a", leaseId: leaseId)] })
        #expect(snapshot.named == [LaunchRef(label: "pool-a", leaseId: leaseId)])
    }

    @Test func aSessionLinksToItsJobBySessionIdToo() throws {
        let t = try TestHome()
        try entry(t, pid: 101, id: "aaaaaaaa-1111")
        try job(t, folder: "x9", id: "aaaaaaaa-1111", naming: try fileURL(t, "pool-a", leaseId))
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        #expect(snapshot.live.first?.refs.count == 1)
    }

    /// JSON reads `true` as the number 1, and `123.9` would read as 123.
    @Test(arguments: ["true", "123.9"])
    func aPidThatIsABooleanOrAFractionIsNoPidButStillNamesItsFile(pid: String) throws {
        let t = try TestHome()
        let url = try fileURL(t, "pool-a", leaseId)
        try write(
            "{\"pid\":\(pid),\"sessionId\":\"aaaaaaaa-1111\",\"args\":[\"--settings\",\"\(url.path)\"]}",
            to: t.home.appendingPathComponent(".claude/sessions/s.json"))
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        #expect(snapshot.live.isEmpty, "\(pid)")
        #expect(snapshot.named == [LaunchRef(label: "pool-a", leaseId: leaseId)], "\(pid)")
        #expect(snapshot.clean, "\(pid)")
    }

    @Test func aWholePidStillNamesALiveSession() throws {
        let t = try TestHome()
        let url = try fileURL(t, "pool-a", leaseId)
        try write(
            "{\"pid\":123,\"sessionId\":\"aaaaaaaa-1111\",\"args\":[\"--settings\",\"\(url.path)\"]}",
            to: t.home.appendingPathComponent(".claude/sessions/s.json"))
        var asked: [Int] = []
        let snapshot = SessionsReader.read(context: t.context) { pid in
            asked.append(pid)
            return true
        }
        #expect(asked == [123])
        #expect(snapshot.live.map(\.id) == ["aaaaaaaa-1111"])
    }

    @Test func onlyAliveSessionsCountButEveryRecordNamesItsFile() throws {
        let t = try TestHome()
        let url = try fileURL(t, "pool-a", leaseId)
        try entry(t, pid: 101, id: "aaaaaaaa-1111", jobId: "j1")
        try job(t, folder: "j1", id: "aaaaaaaa-1111", naming: url)
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in false })
        #expect(snapshot.live.isEmpty && snapshot.clean)
        #expect(snapshot.named.count == 1)
    }

    @Test func aFinishedJobNeverCountsButItsFileIsStillNamed() throws {
        let t = try TestHome()
        let url = try fileURL(t, "pool-a", leaseId)
        try entry(t, pid: 101, id: "aaaaaaaa-1111", jobId: "j1")
        try job(t, folder: "j1", id: "aaaaaaaa-1111", naming: url, state: "finished")
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        #expect(snapshot.live.isEmpty)
        #expect(snapshot.named.count == 1)
    }

    @Test func aForegroundSessionNamesNoFile() throws {
        let t = try TestHome()
        try entry(t, pid: 101, id: "aaaaaaaa-1111")
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        #expect(snapshot.live.first?.refs == [])
    }

    @Test func aNameIsTakenFromAnyStringAndEscapedSlashesAreUndone() throws {
        let t = try TestHome()
        let escaped = try fileURL(t, "pool-a", leaseId).path.replacingOccurrences(
            of: "/", with: "\\/")
        try write(
            "{\"sessionId\":\"s1\",\"respawnFlags\":[\"x\"],\"nested\":{\"deep\":[\"--settings \(escaped)\"]}}",
            to: t.home.appendingPathComponent(".claude/jobs/j1/state.json"))
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        #expect(snapshot.named == [LaunchRef(label: "pool-a", leaseId: leaseId)])
    }

    @Test func theLabelComesFromThePathNotFromAField() throws {
        let t = try TestHome()
        let url = try fileURL(t, "pool-a", leaseId)
        try write(
            "{\"sessionId\":\"s1\",\"AGENT_BALANCER_ACCOUNT\":\"main\",\"p\":\"\(url.path)\"}",
            to: t.home.appendingPathComponent(".claude/jobs/j1/state.json"))
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        #expect(snapshot.named.map(\.label) == ["pool-a"])
    }

    @Test func aRecordThatDoesNotParseMakesThePassUnclean() throws {
        let t = try TestHome()
        try write("not json", to: t.home.appendingPathComponent(".claude/sessions/1.json"))
        #expect(!SessionsReader.read(context: t.context).clean)
        let u = try TestHome()
        try write("[1]", to: u.home.appendingPathComponent(".claude/jobs/j1/state.json"))
        #expect(!SessionsReader.read(context: u.context).clean)
    }

    @Test func aLinkedRecordAndAnOversizedRecordMakeThePassUnclean() throws {
        let t = try TestHome()
        let target = t.home.appendingPathComponent("elsewhere.json")
        try write("{\"pid\":1,\"sessionId\":\"s\"}", to: target)
        let sessions = t.home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent("9.json"), withDestinationURL: target)
        #expect(!SessionsReader.read(context: t.context, isAlive: { _ in true }).clean)

        let u = try TestHome()
        try write(
            "{\"sessionId\":\"s\",\"pad\":\"" + String(repeating: "a", count: 1_100_000) + "\"}",
            to: u.home.appendingPathComponent(".claude/jobs/j1/state.json"))
        #expect(!SessionsReader.read(context: u.context).clean)
    }

    @Test func otherFilesInTheFoldersAreIgnored() throws {
        let t = try TestHome()
        try write("secret", to: t.home.appendingPathComponent(".claude/sessions/12792.abcd.key"))
        try write("x", to: t.home.appendingPathComponent(".claude/jobs/j1/timeline.jsonl"))
        #expect(SessionsReader.read(context: t.context) == .empty)
    }

    @Test func namesAreScrubbedAndCapped() throws {
        let t = try TestHome()
        try entry(
            t, pid: 101, id: "aaaaaaaa-1111",
            name: Canaries.email() + String(repeating: "z", count: 200))
        let snapshot = SessionsReader.read(context: t.context, isAlive: { _ in true })
        let name = snapshot.live.first?.name ?? ""
        #expect(!name.contains("@") && name.count <= 83)
    }

    // MARK: Upkeep

    func put(_ t: TestHome, _ label: String, _ id: String, age: TimeInterval, mode: Int = 0o600)
        throws -> URL
    {
        let url = try fileURL(t, label, id)
        try write("{}", to: url, mode: mode, age: age)
        return url
    }

    func run(
        _ t: TestHome, _ snapshot: SessionsSnapshot, leases: [Lease] = [], keepDays: Int = 35
    ) -> Int {
        Upkeep.run(
            context: t.context, snapshot: snapshot, openLeases: leases, leaseMinutes: 10,
            keepDays: keepDays, now: Date())
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func aFileNoRecordNamesGoesOnceItsLeaseEnded() throws {
        let t = try TestHome()
        let old = try put(t, "pool-a", "l-00000001", age: 20 * 60)
        let young = try put(t, "pool-a", "l-00000002", age: 2 * 60)
        #expect(run(t, .empty) == 1)
        #expect(!exists(old) && exists(young))
    }

    @Test func aFileWithAnOpenLeaseStays() throws {
        let t = try TestHome()
        let url = try put(t, "pool-a", "l-00000001", age: 20 * 60)
        let lease = Lease(id: "l-00000001", label: "pool-a", model: "default", at: Date())
        #expect(run(t, .empty, leases: [lease]) == 0)
        #expect(exists(url))
    }

    @Test func aFileAnyRecordNamesStaysWhateverTheSessionState() throws {
        let t = try TestHome()
        let url = try put(t, "pool-a", "l-00000001", age: 90 * 86_400)
        let ref = LaunchRef(label: "pool-a", leaseId: "l-00000001")
        let snapshot = SessionsSnapshot(clean: true, live: [], named: [ref])
        #expect(run(t, snapshot) == 0)
        #expect(exists(url))
        // Once the record is gone the file goes.
        #expect(run(t, .empty) == 1)
        #expect(!exists(url))
    }

    @Test func withUnreadableRecordsOnlyFilesOlderThanKeepDaysGo() throws {
        let t = try TestHome()
        let recent = try put(t, "pool-a", "l-00000001", age: 3 * 86_400)
        let old = try put(t, "pool-a", "l-00000002", age: 40 * 86_400)
        #expect(run(t, .unreadable) == 1)
        #expect(exists(recent) && !exists(old))
    }

    @Test func onlyRegularFilesOfTheRightNameGoAndALinkIsNeverFollowed() throws {
        let t = try TestHome()
        let dir = try fileURL(t, "pool-a", "l-00000001").deletingLastPathComponent()
        let stray = dir.appendingPathComponent("notes.json")
        try write("{}", to: stray, age: 90 * 86_400)
        let target = t.home.appendingPathComponent("elsewhere.json")
        try write("keep", to: target, age: 90 * 86_400)
        let link = dir.appendingPathComponent("l-cafecafe.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(run(t, .empty) == 0)
        #expect(exists(stray) && exists(target))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(run(t, .unreadable) == 0)
        #expect(exists(target))
    }
}
