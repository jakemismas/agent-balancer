import Foundation
import Testing

@testable import Core

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// Every sign-in here takes a token in the shape recorded for a real one.
private func oauth() -> String { Canary.realShapeToken() }

/// A command run as a child process from a thread of its own, so the test can act while it runs
/// and never waits on the shared dispatch pool for it.
private final class Started: @unchecked Sendable {
    private let lock = NSLock()
    private let ended = DispatchSemaphore(value: 0)
    private var output: Support.Output?
    private var finished = false

    init(_ cli: CLIHome, _ args: [String]) {
        let thread = Thread { [self] in
            let out = try? cli.run(args)
            lock.lock()
            output = out
            finished = true
            lock.unlock()
            ended.signal()
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// True once the command has ended.
    var hasEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// The command's output once it has ended, or nil when it still runs after five minutes.
    func wait() -> Support.Output? {
        guard ended.wait(timeout: .now() + 300) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return output
    }
}

/// add, login, remove and the token checks end to end against the fake `claude`.
@Suite struct TokenAccountsCLITests {
    func setUp() throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        try cli.fakeProbe("ok.jsonl")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: [
            Account(
                label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
                expectedPlanTier: "max_20x")
        ])
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        return cli
    }

    func object(_ out: Support.Output) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
    }

    func row(_ cli: CLIHome, _ label: String) throws -> [String: Any] {
        let doc = try object(cli.run(["status", "--cached", "--json"]))
        let rows = try #require(doc["accounts"] as? [[String: Any]])
        return try #require(rows.first { $0["label"] as? String == label })
    }

    func events(_ cli: CLIHome, type: String? = nil, label: String? = nil) throws -> [[String: Any]]
    {
        var args = ["events", "--json"]
        if let type { args += ["--type", type] }
        if let label { args += ["--label", label] }
        let doc = try object(cli.run(args))
        return try #require(doc["events"] as? [[String: Any]])
    }

    func tokenFile(_ cli: CLIHome, _ label: String) throws -> URL {
        try TokenPaths.fileURL(
            context: ToolContext(home: cli.home, ambient: [:]), label: label)
    }

    func config(_ cli: CLIHome) throws -> [[String: Any]] {
        let data = Data(cli.read("config.json").utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["accounts"] as? [[String: Any]])
    }

    /// The text of every file under the data folder except the token files and the launch files.
    func nonTokenText(_ cli: CLIHome) -> String {
        var out = ""
        let tokenFolder = TokenPaths.folders[0]
        let launchFolder = LaunchFiles.rootURL(context: ToolContext(home: cli.home, ambient: [:]))
            .lastPathComponent
        for url in cli.dataEntries() {
            let parts = url.pathComponents
            if parts.contains(tokenFolder) || parts.contains(launchFolder) { continue }
            out += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return out
    }

    // MARK: add

    @Test func addWritesOnlyTheRegistryEntryAndAnAddedEvent() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let out = try cli.run([
            "add", "lab", "--email", "lab@example.com", "--ends", "2099-12-31",
        ])
        #expect(out.status == 0, "\(text(out.stderr))")
        let entry = try #require(try config(cli).first { $0["label"] as? String == "lab" })
        #expect(entry["kind"] as? String == "token")
        #expect(entry["role"] as? String == "pool")
        #expect(entry["email"] as? String == "lab@example.com")
        #expect(entry["endsAt"] as? String == "2099-12-31")
        #expect(entry["endingSoon"] == nil)
        #expect((entry["accountKey"] as? String)?.count == 32)
        #expect(entry["tokenCreatedAt"] == nil)
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
        // No folder either, and no sign-in: the next step is printed for the person to run.
        let context = ToolContext(home: cli.home, ambient: [:])
        #expect(
            !FileManager.default.fileExists(
                atPath: try tokenFile(cli, "lab").deletingLastPathComponent().path))
        #expect(!FileManager.default.fileExists(atPath: LaunchFiles.rootURL(context: context).path))
        #expect(text(out.stdout).contains("Next, run `agent-balancer login lab` in Terminal"))
        #expect(!cli.fakeRecord("args.log").contains("setup-token"))
        #expect(try events(cli, type: "account_added", label: "lab").count == 1)
        let shown = try row(cli, "lab")
        #expect((shown["error"] as? [String: Any])?["code"] as? String == "token_missing")
        #expect(cli.expectPrivateModes().isEmpty)
    }

    @Test func addRefusesBadInputAndWritesNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let before = cli.read("config.json")
        for args in [
            ["add", "Bad Label"], ["add", "main"], ["add", "lab", "--kind", "login"],
            ["add", "lab", "--kind", "bogus"], ["add", "lab", "--email", "nope"],
            ["add", "lab", "--ends", "soon"], ["add", "lab", "--ends", "2020-01-01"],
            ["add", "lab", "--ends", "2026-02-30"],
        ] {
            let out = try cli.run(args)
            #expect(out.status == 1, "\(args)")
        }
        #expect(cli.read("config.json") == before)
        let bogus = try cli.run(["add", "lab", "--kind", "bogus"])
        #expect(text(bogus.stderr).contains("The kind must be token or folder."))
        let today = Self.localDay(Date())
        #expect(try cli.run(["add", "lab", "--ends", today]).status == 0)
        let entry = try #require(try config(cli).first { $0["label"] as? String == "lab" })
        #expect(entry["endsAt"] as? String == today)
    }

    static func localDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: login

    func addLab(_ cli: CLIHome, _ label: String = "lab") throws {
        let out = try cli.run(["add", label])
        #expect(out.status == 0, "\(text(out.stderr))")
    }

    @Test func loginTakesTheTokenWithoutShowingItAndProbesUnderIt() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let token = oauth()
        try cli.fake("setup-token.out", "Open the page.\nYour token is \(token)\n")
        let out = try cli.run(["login", "lab"])
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(!cli.everythingUnderData(out, excluding: try tokenFile(cli, "lab")).contains(token))

        let file = try tokenFile(cli, "lab")
        #expect(cli.mode(file) == 0o600)
        #expect(cli.mode(file.deletingLastPathComponent()) == 0o700)
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved.count == 1)
        #expect(
            saved["env"] as? [String: String] == [
                ProtectedEnv.tokenVariable: token, LaunchFiles.accountVariable: "lab",
            ])
        #expect(cli.expectPrivateModes().isEmpty)
        #expect(text(out.stdout).contains("First check: read"))

        let entry = try #require(try config(cli).first { $0["label"] as? String == "lab" })
        #expect(entry["tokenCreatedAt"] as? String != nil)

        // One probe ran, and it named the token file and no config folder.
        let probes = cli.fakeRecord("args.log").split(separator: "\n").filter {
            $0.hasPrefix("-p ")
        }
        #expect(probes.count == 1)
        #expect(probes[0].contains("--settings \(file.path)"))
        #expect(cli.fakeRecord("config-dir.txt").contains("unset"))
        #expect(!cli.fakeRecord("env-names.txt").contains(ProtectedEnv.tokenVariable))

        // The row reads the estimate of a year from the saved time.
        let shown = try row(cli, "lab")
        #expect(shown["error"] is NSNull || shown["error"] == nil)
        #expect(shown["loginExpiresSource"] as? String == "estimate")
        let expires = try #require(shown["loginExpiresAt"] as? String)
        let date = try #require(ISO8601DateFormatter().date(from: expires))
        let days = date.timeIntervalSinceNow / 86_400
        #expect(days > 364 && days < 366)
        #expect(try events(cli, type: "token_replaced").isEmpty)
    }

    @Test func loginRefusesInAChatShellAndStartsNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fake("setup-token.out", oauth() + "\n")
        let started = cli.fakeRecord("args.log")
        let out = try cli.run(["login", "lab"], env: ["CLAUDE_CODE_CHILD_SESSION": ""])
        #expect(out.status == 1)
        #expect(
            text(out.stderr).contains(
                "Run this in your own terminal, outside a Claude Code session."))
        #expect(!cli.fakeRecord("args.log").contains("setup-token"))
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
        let paste = try cli.run(
            ["login", "lab", "--paste"], env: ["CLAUDE_CODE_CHILD_SESSION": "1"],
            stdin: oauth() + "\n")
        #expect(paste.status == 1)
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
        // The fake claude records every start; neither form started it.
        #expect(cli.fakeRecord("args.log") == started)
    }

    @Test func loginRefusesAnAccountThatIsNotAToken() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let out = try cli.run(["login", "main"])
        #expect(out.status == 1)
        let missing = try cli.run(["login", "nobody"])
        #expect(missing.status == 1)
        #expect(!cli.fakeRecord("args.log").contains("setup-token"))
    }

    @Test func noTokenInTheOutputExitsOneAndSavesNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let key = Canary.all()[1].value
        try cli.fake("setup-token.out", "Something else \(key)\n")
        let out = try cli.run(["login", "lab"])
        #expect(out.status == 1)
        #expect(!(text(out.stdout) + text(out.stderr)).contains(key))
        #expect(text(out.stderr).contains("agent-balancer login lab --paste"))
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
        #expect(!cli.read("config.json").contains("tokenCreatedAt"))
    }

    @Test func aFailedSetupTokenRunExitsOneAndSavesNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fake("setup-token.err", "Sign-in was cancelled.\n")
        try cli.fake("setup-token.exit", "1")
        let out = try cli.run(["login", "lab"])
        #expect(out.status == 1)
        #expect(cli.fakeRecord("args.log").contains("setup-token"))
        #expect(text(out.stderr).contains("--paste"))
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
        #expect(!cli.read("config.json").contains("tokenCreatedAt"))
    }

    @Test func pasteReadsFromInputNeverFromAnArgument() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let token = oauth()
        let out = try cli.run(["login", "lab", "--paste"], stdin: token + "\n")
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(try String(contentsOf: try tokenFile(cli, "lab"), encoding: .utf8).contains(token))
        #expect(!cli.everythingUnderData(out, excluding: try tokenFile(cli, "lab")).contains(token))
        #expect(!cli.fakeRecord("args.log").contains(token))
        #expect(!cli.fakeRecord("args.log").contains("setup-token"))
    }

    @Test func pasteRefusesAWrongShapeAndAnApiKey() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        for bad in ["hello world", Canary.all()[1].value, ""] {
            let out = try cli.run(["login", "lab", "--paste"], stdin: bad + "\n")
            #expect(out.status == 1)
            #expect(!(text(out.stdout) + text(out.stderr)).contains(bad) || bad.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
    }

    @Test func aFailedFirstCheckKeepsTheTokenAndExitsOne() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fake("setup-token.out", oauth() + "\n")
        try cli.fake("probe.jsonl", "{\"type\":\"result\",\"is_error\":true,\"result\":\"401\"}\n")
        try cli.fake("probe.exit", "1")
        let out = try cli.run(["login", "lab"])
        #expect(out.status == 1)
        #expect(FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
        #expect(text(out.stdout).contains("First check failed"))
    }

    // MARK: replace and remove

    @Test func replaceRewritesLaunchFilesAndWritesOneEvent() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let old = oauth()
        try cli.fake("setup-token.out", old + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)

        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        #expect(pick.status == 0, "\(text(pick.stderr))")
        let answer = try object(pick)
        #expect(answer["label"] as? String == "lab")
        let args = try #require(answer["args"] as? [String])
        let launchFile = URL(fileURLWithPath: args[1])
        #expect(try String(contentsOf: launchFile, encoding: .utf8).contains(old))

        let fresh = oauth()
        try cli.fake("setup-token.out", fresh + "\n")
        let out = try cli.run(["login", "lab"])
        #expect(out.status == 0, "\(text(out.stderr))")
        let body = try String(contentsOf: launchFile, encoding: .utf8)
        #expect(body.contains(fresh) && !body.contains(old))
        #expect(cli.mode(launchFile) == 0o600)
        #expect(text(out.stdout).contains("old token may keep working until its year ends"))
        let replaced = try events(cli, type: "token_replaced")
        #expect(replaced.count == 1)
        #expect(replaced.first?["label"] as? String == "lab")
        // Nothing but the token file and that label's launch file carries a token.
        #expect(!nonTokenText(cli).contains(old) && !nonTokenText(cli).contains(fresh))
        #expect(!cli.everything(out).contains(old))

        // Each replace writes its own event and says it again.
        let third = oauth()
        try cli.fake("setup-token.out", third + "\n")
        let again = try cli.run(["login", "lab"])
        #expect(again.status == 0, "\(text(again.stderr))")
        #expect(text(again.stdout).contains("old token may keep working until its year ends"))
        #expect(try events(cli, type: "token_replaced").count == 2)
        let last = try String(contentsOf: launchFile, encoding: .utf8)
        #expect(last.contains(third) && !last.contains(fresh))
        #expect(!cli.everything(again).contains(old) && !cli.everything(again).contains(fresh))
    }

    @Test func removeDeletesEverythingItMadeAndSaysTheTokenLivesOn() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fake("setup-token.out", oauth() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        let args = try #require(try object(pick)["args"] as? [String])
        let launchFile = URL(fileURLWithPath: args[1])
        #expect(FileManager.default.fileExists(atPath: launchFile.path))
        // The pick's lease has ended, so nothing is left to keep a tombstone for.
        try endLeases(cli)

        let out = try cli.run(["remove", "lab"])
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(text(out.stdout).contains("token itself may keep working until its year ends"))
        #expect(try leases(cli).allSatisfy { $0.label != "lab" })
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
        #expect(!FileManager.default.fileExists(atPath: launchFile.path))
        #expect(
            !FileManager.default.fileExists(atPath: launchFile.deletingLastPathComponent().path))
        #expect(try config(cli).allSatisfy { $0["label"] as? String != "lab" })
        #expect(try events(cli, type: "account_removed", label: "lab").count == 1)
        #expect(!cli.read("state/readings/lab.json").contains("readAt"))
        #expect(cli.expectPrivateModes().isEmpty)

        let again = try cli.run(["remove", "lab"])
        #expect(again.status == 1)
    }

    @Test func removeKeepsATokenFreeCopyOfALaunchFileASessionStillNames() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let secret = oauth()
        try cli.fake("setup-token.out", secret + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        let args = try #require(try object(pick)["args"] as? [String])
        let launchFile = URL(fileURLWithPath: args[1])
        let sessions = cli.home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try "{\"sessionId\":\"s1\",\"pid\":1,\"args\":[\"\(launchFile.path)\"]}".write(
            to: sessions.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        // The pick's lease has ended, so only the session record keeps the file.
        try endLeases(cli)

        let out = try cli.run(["remove", "lab"])
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(text(out.stdout).contains("Kept 1 launch files"))
        let kept = try String(contentsOf: launchFile, encoding: .utf8)
        #expect(!kept.contains(secret))
        #expect(try launchEnv(launchFile) == tombstone("lab"))
        #expect(!nonTokenText(cli).contains(secret))
    }

    func leases(_ cli: CLIHome) throws -> [Lease] {
        try LeaseStore(context: ToolContext(home: cli.home, ambient: [:])).current(
            now: Date(), leaseMinutes: 525_600)
    }

    /// Moves every lease an hour into the past, as if its time had run out.
    func endLeases(_ cli: CLIHome) throws {
        let store = LeaseStore(context: ToolContext(home: cli.home, ambient: [:]))
        try store.save(
            try leases(cli).map {
                var lease = $0
                lease.at = Date().addingTimeInterval(-3_600)
                return lease
            })
    }

    func launchEnv(_ url: URL) throws -> [String: String]? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let object, object.count == 1 else { return nil }
        return object["env"] as? [String: String]
    }

    func tombstone(_ label: String) -> [String: String] {
        [ProtectedEnv.tokenVariable: "invalid", LaunchFiles.accountVariable: label]
    }

    @Test func removeRightAfterAPickKeepsATombstoneOfItsLaunchFile() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let secret = oauth()
        try cli.fake("setup-token.out", secret + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        let args = try #require(try object(pick)["args"] as? [String])
        let launchFile = URL(fileURLWithPath: args[1])

        let out = try cli.run(["remove", "lab"])
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(text(out.stdout).contains("Kept 1 launch files"))
        #expect(try launchEnv(launchFile) == tombstone("lab"))
        #expect(cli.mode(launchFile) == 0o600)
        #expect(try leases(cli).allSatisfy { $0.label != "lab" })
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
        #expect(!cli.everything(out).contains(secret))
    }

    @Test func removeFinishesOnARerunWhenTheAccountEntryIsAlreadyGone() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let secret = oauth()
        try cli.fake("setup-token.out", secret + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        let args = try #require(try object(pick)["args"] as? [String])
        let launchFile = URL(fileURLWithPath: args[1])
        // A remove that stopped after the entry went leaves the files behind.
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        var registry = try store.loadRequired()
        registry.accounts.removeAll { $0.label == "lab" }
        try store.save(registry)

        let doctor = try cli.run(["doctor"])
        #expect(
            text(doctor.stdout).contains("a token file is saved for 'lab', which has no account"))
        let out = try cli.run(["remove", "lab"])
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(text(out.stdout).contains("Removed what was left of 'lab'."))
        #expect(text(out.stdout).contains("token itself may keep working until its year ends"))
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
        #expect(try launchEnv(launchFile) == tombstone("lab"))
        #expect(try leases(cli).allSatisfy { $0.label != "lab" })
        #expect(!cli.everything(out).contains(secret))
        #expect(!text(try cli.run(["doctor"]).stdout).contains("which has no account"))
        // Nothing is left, so a further rerun has nothing to finish.
        #expect(try cli.run(["remove", "lab"]).status == 1)
    }

    @Test func doctorListsTheWritersLeftoversAndRemoveLeavesTheirTokenNowhere() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let secret = oauth()
        try cli.fake("setup-token.out", secret + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        let args = try #require(try object(pick)["args"] as? [String])
        let launchFile = URL(fileURLWithPath: args[1])
        // A login and a pick killed between their write and their rename leave these behind.
        let body = "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(secret)\"}}"
        let leftovers = [
            try tokenFile(cli, "lab").deletingLastPathComponent()
                .appendingPathComponent(".tmp-0123456789abcdef"),
            launchFile.deletingLastPathComponent().appendingPathComponent(".tmp-fedcba9876543210"),
        ]
        for url in leftovers {
            try body.write(to: url, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let doctor = try cli.run(["doctor"])
        #expect(text(doctor.stdout).contains("Warning: 2 temporary files"))
        #expect(!text(doctor.stdout).contains(secret))

        try endLeases(cli)
        let out = try cli.run(["remove", "lab"])
        #expect(out.status == 0, "\(text(out.stderr))")
        for url in leftovers {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        // The canary is nowhere under the data folder and in no output.
        var collected = Collected()
        try collected.addFiles(under: cli.dataRoot)
        collected.streams["stdout"] = out.stdout
        collected.streams["stderr"] = out.stderr
        #expect(collected.leaks(of: [Canary(name: "secret", value: secret)]).isEmpty)
        #expect(!text(try cli.run(["doctor"]).stdout).contains("temporary files"))
    }

    @Test func theRefreshDoctorAdvisesDeletesTheWritersLeftovers() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let secret = oauth()
        try cli.fake("setup-token.out", secret + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        let leftover = try tokenFile(cli, "lab").deletingLastPathComponent()
            .appendingPathComponent(".tmp-0123456789abcdef")
        try "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(secret)\"}}".write(
            to: leftover, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: leftover.path)
        #expect(text(try cli.run(["doctor"]).stdout).contains("Warning: 1 temporary files"))

        _ = try cli.run(["refresh"])
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(!text(try cli.run(["doctor"]).stdout).contains("temporary files"))
    }

    @Test func theRefreshDoctorAdvisesDeletesTheLeftoversWithNoAccounts() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
            .save(Config(accounts: []))
        let folder = try tokenFile(cli, "lab").deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let leftover = folder.appendingPathComponent(".tmp-0123456789abcdef")
        try "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(oauth())\"}}".write(
            to: leftover, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: leftover.path)
        #expect(text(try cli.run(["doctor"]).stdout).contains("Warning: 1 temporary files"))

        let out = try cli.run(["refresh"])
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(text(out.stdout).contains("No accounts to refresh."))
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(!text(try cli.run(["doctor"]).stdout).contains("temporary files"))
    }

    @Test func aLoginThatARemoveOvertookSavesNoToken() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fake("setup-token.out", oauth() + "\n")
        // The fake waits before it answers, as a person approving in the browser does.
        try cli.fake("delay", "3")
        let task = Process()
        task.executableURL = cli.exe
        task.arguments = ["login", "lab"]
        task.environment = ["HOME": cli.home.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let deadline = Date().addingTimeInterval(20)
        while !cli.fakeRecord("args.log").contains("setup-token") && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(cli.fakeRecord("args.log").contains("setup-token"))

        let removed = try cli.run(["remove", "lab"])
        #expect(removed.status == 0, "\(text(removed.stderr))")
        task.waitUntilExit()
        let said = text(output.fileHandleForReading.readDataToEndOfFile())
        #expect(task.terminationStatus == 1, "\(said)")
        #expect(said.contains("No account is labelled 'lab'"))
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))
        try FileManager.default.removeItem(at: cli.home.appendingPathComponent(".ab-fake/delay"))
        #expect(!text(try cli.run(["doctor"]).stdout).contains("which has no account"))
        #expect(try cli.run(["remove", "lab"]).status == 1)
    }

    @Test func addRefusesALabelWhoseTokenFileOutlivedItsAccount() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // A remove that stopped after the entry went leaves the token file behind.
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        var registry = try store.loadRequired()
        registry.accounts.removeAll { $0.label == "lab" }
        try store.save(registry)

        let refused = try cli.run(["add", "lab"])
        #expect(refused.status == 1)
        #expect(text(refused.stderr).contains("Run `agent-balancer remove lab` in Terminal first"))
        #expect(try config(cli).allSatisfy { $0["label"] as? String != "lab" })
        #expect(FileManager.default.fileExists(atPath: try tokenFile(cli, "lab").path))

        #expect(try cli.run(["remove", "lab"]).status == 0)
        #expect(try cli.run(["add", "lab"]).status == 0)
        // The account added again has no token until its own login.
        let out = try cli.run(["pick", "--dry-run", "--json"])
        let list = try #require(try object(out)["candidates"] as? [[String: Any]])
        let lab = try #require(list.first { $0["label"] as? String == "lab" })
        #expect(lab["eligible"] as? Bool == false)
        #expect(lab["reason"] as? String == "no token saved")
    }

    @Test func removeNeverFollowsOrDeletesALinkPlantedAsTheTokenFile() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        let file = try tokenFile(cli, "lab")
        let outside = cli.home.appendingPathComponent("outside.txt")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)

        let out = try cli.run(["remove", "lab"])
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(!text(out.stdout).contains("Deleted the token file."))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path))
                == outside.path)
    }

    @Test func removeRefusesInAChatShell() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let out = try cli.run(["remove", "lab"], env: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        #expect(out.status == 1)
        #expect(try config(cli).contains { $0["label"] as? String == "lab" })
    }

    @Test func bothFoldersAreMarkedExcludedFromBackups() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fake("setup-token.out", oauth() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        let context = ToolContext(home: cli.home, ambient: [:])
        let name = "com.apple.metadata:com_apple_backup_excludeItem"
        let tokens = try tokenFile(cli, "lab").deletingLastPathComponent()
        let launch = LaunchFiles.rootURL(context: context)
        #expect(getxattr(tokens.path, name, nil, 0, 0, 0) >= 0)
        #expect(getxattr(launch.path, name, nil, 0, 0, 0) >= 0)
    }

    // MARK: duplicate and token_missing

    func probeText(_ cli: CLIHome, week: Int, five: Int) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        return try String(
            contentsOf: cli.fixtures.appendingPathComponent("probe/ok.jsonl"), encoding: .utf8
        )
        .replacingOccurrences(of: "@RESET_5H@", with: "\(now + five)")
        .replacingOccurrences(of: "@RESET_7D@", with: "\(now + week)")
    }

    @Test func equalResetTimesWarnOnLoginAndOnEveryLaterProbe() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli, "lab-a")
        try addLab(cli, "lab-b")
        let same = try probeText(cli, week: 400_000, five: 10_000)
        try cli.fake("probe.jsonl", same)
        try cli.fake("setup-token.out", oauth() + "\n")
        let first = try cli.run(["login", "lab-a"])
        #expect(first.status == 0)
        #expect(!text(first.stdout).contains("possible_duplicate"))
        try cli.fake("setup-token.out", oauth() + "\n")
        let second = try cli.run(["login", "lab-b"])
        #expect(second.status == 0)
        #expect(text(second.stdout).contains("Warning possible_duplicate"))
        #expect(text(second.stdout).contains("lab-a"))
        let shown = try row(cli, "lab-b")
        let warnings = try #require(shown["warnings"] as? [[String: Any]])
        #expect(warnings.contains { $0["code"] as? String == "possible_duplicate" })
        #expect(shown["error"] == nil || shown["error"] is NSNull)
        // A warning only: pick still offers both accounts.
        let pick = try cli.run(["pick", "--dry-run", "--json"])
        let candidates = try #require(try object(pick)["candidates"] as? [[String: Any]])
        for label in ["lab-a", "lab-b"] {
            let candidate = try #require(candidates.first { $0["label"] as? String == label })
            #expect(candidate["eligible"] as? Bool == true, "\(label)")
        }

        // The stored reading is dropped so the next probe is read as new. A probe that answers
        // with other times clears the warning; one that answers with equal times raises it.
        let reading = cli.dataRoot.appendingPathComponent("state/readings/lab-b.json")
        let other = try probeText(cli, week: 300_000, five: 5_000)
        try cli.fake("probe-for-lab-b.jsonl", other)
        try FileManager.default.removeItem(at: reading)
        #expect(try cli.run(["refresh", "--label", "lab-b", "--force"]).status == 0)
        let after = try #require(try row(cli, "lab-b")["warnings"] as? [[String: Any]])
        #expect(!after.contains { $0["code"] as? String == "possible_duplicate" })

        try cli.fake("probe-for-lab-b.jsonl", same)
        try FileManager.default.removeItem(at: reading)
        #expect(try cli.run(["refresh", "--label", "lab-b", "--force"]).status == 0)
        let swapped = try #require(try row(cli, "lab-b")["warnings"] as? [[String: Any]])
        #expect(swapped.contains { $0["code"] as? String == "possible_duplicate" })
    }

    /// lab-a reads a weekly reset 400000 seconds out and a 5-hour reset 10000 seconds out. Only
    /// both equal warn: equal weekly only, equal 5-hour only and neither do not.
    @Test(arguments: [(400_000, 10_000), (350_000, 10_000), (400_000, 5_000), (350_000, 5_000)])
    func differentResetTimesGiveNoWarning(week: Int, five: Int) throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli, "lab-a")
        try addLab(cli, "lab-b")
        // Main reads other times, so only lab-a can match lab-b.
        try cli.fake("probe.jsonl", try probeText(cli, week: 200_000, five: 2_000))
        try cli.fake("probe-for-lab-a.jsonl", try probeText(cli, week: 400_000, five: 10_000))
        try cli.fake("probe-for-lab-b.jsonl", try probeText(cli, week: week, five: five))
        try cli.fake("setup-token.out", oauth() + "\n")
        let first = try cli.run(["login", "lab-a"])
        #expect(first.status == 0)
        #expect(!text(first.stdout).contains("possible_duplicate"))
        try cli.fake("setup-token.out", oauth() + "\n")
        let out = try cli.run(["login", "lab-b"])
        #expect(out.status == 0)
        let both = week == 400_000 && five == 10_000
        #expect(text(out.stdout).contains("possible_duplicate") == both, "\(week) \(five)")
        let warnings = try row(cli, "lab-b")["warnings"] as? [[String: Any]] ?? []
        #expect(warnings.contains { $0["code"] as? String == "possible_duplicate" } == both)
    }

    @Test func aTokenFileSwappedForAnotherAccountsTokenWarnsOnTheNextProbe() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.fake("probe.jsonl", try probeText(cli, week: 200_000, five: 2_000))
        try addLab(cli, "lab-a")
        try addLab(cli, "lab-b")
        let tokenA = oauth()
        let tokenB = oauth()
        // The fake answers each token with its own reset times, as the service would.
        try cli.fake("token-stream-a.token", tokenA)
        try cli.fake("token-stream-a.jsonl", try probeText(cli, week: 400_000, five: 10_000))
        try cli.fake("token-stream-b.token", tokenB)
        try cli.fake("token-stream-b.jsonl", try probeText(cli, week: 300_000, five: 5_000))
        try cli.fake("setup-token.out", tokenA + "\n")
        #expect(try cli.run(["login", "lab-a"]).status == 0)
        try cli.fake("setup-token.out", tokenB + "\n")
        let second = try cli.run(["login", "lab-b"])
        #expect(second.status == 0)
        #expect(!text(second.stdout).contains("possible_duplicate"))

        // lab-b's file now holds lab-a's token. The next probe reads lab-a's times.
        let file = try tokenFile(cli, "lab-b")
        let swapped =
            "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(tokenA)\",\"\(LaunchFiles.accountVariable)\":\"lab-b\"}}"
        try swapped.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.removeItem(
            at: cli.dataRoot.appendingPathComponent("state/readings/lab-b.json"))
        #expect(try cli.run(["refresh", "--label", "lab-b", "--force"]).status == 0)
        let shown = try row(cli, "lab-b")
        let warnings = try #require(shown["warnings"] as? [[String: Any]])
        let duplicate = try #require(
            warnings.first { $0["code"] as? String == "possible_duplicate" })
        #expect((duplicate["text"] as? String)?.contains("lab-a") == true)
        #expect(shown["error"] == nil || shown["error"] is NSNull)
        // The warning writes no event.
        let all = try events(cli)
        #expect(!all.contains { $0["code"] as? String == "possible_duplicate" })
        #expect(!all.contains { $0["type"] as? String == "possible_duplicate" })
    }

    @Test func aStoredWarningThatNamesARemovedAccountIsHidden() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli, "lab-a")
        try addLab(cli, "lab-b")
        // Main reads other times, so only lab-a can match lab-b.
        try cli.fake("probe.jsonl", try probeText(cli, week: 200_000, five: 2_000))
        let same = try probeText(cli, week: 400_000, five: 10_000)
        try cli.fake("probe-for-lab-a.jsonl", same)
        try cli.fake("probe-for-lab-b.jsonl", same)
        try cli.fake("setup-token.out", oauth() + "\n")
        #expect(try cli.run(["login", "lab-a"]).status == 0)
        try cli.fake("setup-token.out", oauth() + "\n")
        let second = try cli.run(["login", "lab-b"])
        #expect(text(second.stdout).contains("Warning possible_duplicate"))

        #expect(try cli.run(["remove", "lab-a"]).status == 0)
        // lab-b is not probed again, so its stored check still names lab-a.
        let current = try #require(
            JSONSerialization.jsonObject(with: Data(cli.read("state/current.json").utf8))
                as? [String: Any])
        let stored = try #require(current["accounts"] as? [String: [String: Any]])
        #expect(stored["lab-b"]?["possibleDuplicateOf"] as? String == "lab-a")
        let warnings = try row(cli, "lab-b")["warnings"] as? [[String: Any]] ?? []
        #expect(!warnings.contains { $0["code"] as? String == "possible_duplicate" })
        #expect(!text(try cli.run(["status", "--cached"]).stdout).contains("lab-a"))
    }

    @Test func aProbeAuthErrorShowsLoginRejectedAndPickSkipsTheAccount() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let rejected = try String(
            contentsOf: cli.fixtures.appendingPathComponent("probe/auth_error.jsonl"),
            encoding: .utf8)
        try cli.fake("probe-for-lab.jsonl", rejected)
        try cli.fake("setup-token.out", oauth() + "\n")
        let out = try cli.run(["login", "lab"])
        #expect(out.status == 1)
        #expect(text(out.stdout).contains("login_rejected"))
        let error = try #require(try row(cli, "lab")["error"] as? [String: Any])
        #expect(error["code"] as? String == "login_rejected")
        let pick = try cli.run(["pick", "--dry-run", "--json"])
        let candidates = try #require(try object(pick)["candidates"] as? [[String: Any]])
        let lab = try #require(candidates.first { $0["label"] as? String == "lab" })
        #expect(lab["eligible"] as? Bool == false)
        #expect(lab["reason"] as? String == "login rejected")
    }

    /// How many probes the fake `claude` has run under the token file of `label`.
    func tokenProbeRuns(_ cli: CLIHome, _ label: String) throws -> Int {
        let file = try tokenFile(cli, label)
        return cli.fakeRecord("args.log").split(separator: "\n").filter {
            $0.hasPrefix("-p ") && $0.contains("--settings \(file.path)")
        }.count
    }

    /// `lab` signed in with a fresh reading, then a forced probe that finds its token rejected.
    /// The reading is two minutes old and the status sees it, so a later probe stores a newer one.
    func rejectedLab(_ cli: CLIHome) throws {
        try addLab(cli)
        try loginLab(cli)
        try ageReading(cli, "lab", by: 120)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        #expect(try tokenError(cli)?["code"] as? String == "login_rejected")
    }

    /// `lab` in a pick that leaves `main` out: whether it is eligible, why, and the label picked.
    func labInPick(_ cli: CLIHome, _ flags: [String] = []) throws
        -> (eligible: Bool?, reason: String?, picked: String?)
    {
        let answer = try object(try cli.run(["pick", "--json", "--exclude", "main"] + flags))
        let candidates = try #require(answer["candidates"] as? [[String: Any]])
        let lab = try #require(candidates.first { $0["label"] as? String == "lab" })
        return (lab["eligible"] as? Bool, lab["reason"] as? String, answer["label"] as? String)
    }

    @Test func pickSkipsATokenAccountWhoseProbesRejectionStandsWhileItsReadingIsFresh() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try rejectedLab(cli)
        // The reading `login` stored is still fresh, so no probe of the pick would see the
        // rejection.
        let probes = try tokenProbeRuns(cli, "lab")
        for flags in [["--caller", "launcher"], []] {
            let lab = try labInPick(cli, flags)
            #expect(lab.eligible == false && lab.reason == "login rejected", "\(flags)")
            #expect(lab.picked == nil, "\(flags)")
        }
        #expect(try tokenProbeRuns(cli, "lab") == probes)
    }

    @Test func pickAndRunSkipATokenAccountWhoseFirstCheckWasRejected() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fakeProbe("auth_error.jsonl")
        try cli.fake("setup-token.out", oauth() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 1)
        #expect(try tokenError(cli)?["code"] as? String == "login_rejected")
        // The rejected first check stored no reading.
        #expect(cli.read("state/readings/lab.json").isEmpty)
        let probes = try tokenProbeRuns(cli, "lab")
        let lab = try labInPick(cli)
        #expect(lab.eligible == false && lab.reason == "login rejected")
        #expect(try tokenProbeRuns(cli, "lab") == probes)
        for args in [["run", "lab"], ["run", "lab", "--print-command"]] {
            let out = try cli.run(args)
            #expect(out.status == 1, "\(args)")
            #expect(text(out.stderr).contains(Messages.probeLoginRejected), "\(args)")
        }
    }

    @Test func pickAndRunSkipATokenAccountWhoseRejectionStandsOnAStaleReading() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // The rejection has stood past the reading age: the stored reading is an hour old.
        let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
        var reading = try #require(try store.load(label: "lab"))
        reading.readAt = Date().addingTimeInterval(-3600)
        try store.save(reading, label: "lab")
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        #expect(try tokenError(cli)?["code"] as? String == "login_rejected")
        let probes = try tokenProbeRuns(cli, "lab")
        let lab = try labInPick(cli)
        #expect(lab.eligible == false && lab.reason == "login rejected")
        #expect(try tokenProbeRuns(cli, "lab") == probes)
        for args in [["run", "lab"], ["run", "lab", "--print-command"]] {
            let out = try cli.run(args)
            #expect(out.status == 1, "\(args)")
            #expect(text(out.stderr).contains(Messages.probeLoginRejected), "\(args)")
        }
    }

    @Test func pickAndRunSkipATokenAccountWhoseRejectionStandsOnAReadingTheyCannotRead() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try rejectedLab(cli)
        // The stored reading is there but cannot be read.
        let file = cli.dataRoot.appendingPathComponent("state/readings/lab.json").path
        try #require(chmod(file, 0) == 0)
        defer { chmod(file, 0o600) }
        #expect(throws: (any Error).self) {
            try ReadingStore(context: ToolContext(home: cli.home, ambient: [:])).load(label: "lab")
        }
        let probes = try tokenProbeRuns(cli, "lab")
        // The pick saves the settings verdict that `run` relies on, so it runs first.
        let lab = try labInPick(cli, ["--caller", "launcher"])
        #expect(lab.eligible == false && lab.reason == "login rejected")
        #expect(lab.picked == nil)
        for args in [["run", "lab"], ["run", "lab", "--print-command"]] {
            let out = try cli.run(args)
            #expect(out.status == 1, "\(args)")
            #expect(text(out.stderr).contains(Messages.probeLoginRejected), "\(args)")
        }
        #expect(try tokenProbeRuns(cli, "lab") == probes)
    }

    @Test func aTokenAccountCompetesAgainOnceAReadingNewerThanItsRejectionIsStored() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
        var reading = try #require(try store.load(label: "lab"))
        reading.readAt = Date().addingTimeInterval(-120)
        try store.save(reading, label: "lab")
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        #expect(try labInPick(cli).reason == "login rejected")

        // Another command's probe worked and stored a newer reading before it rebuilt the status.
        reading.readAt = Date().addingTimeInterval(-60)
        try store.save(reading, label: "lab")
        let lab = try labInPick(cli)
        #expect(lab.eligible == true && lab.picked == "lab")
    }

    @Test func runStartsATokenOnceAReadingNewerThanItsRejectionIsStored() throws {
        // Each form in a home of its own, since a run that starts rebuilds the status.
        for flags in [["--print-command"], []] {
            let cli = try setUp()
            defer { cli.cleanup() }
            try cli.fake("default.exit", "0")
            try addLab(cli)
            try loginLab(cli)
            try ageReading(cli, "lab", by: 120)
            #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
            try cli.fakeProbe("auth_error.jsonl")
            #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1, "\(flags)")
            // A reader saves the verdict that `run` relies on.
            _ = try HookRecord(context: ToolContext(home: cli.home, ambient: [:])).readSettings()
            #expect(try cli.run(["run", "lab"] + flags).status == 1, "\(flags)")

            // Another command's probe worked and stored a newer reading before it rebuilt the
            // status, so `run` starts lab, as `pick` offers it.
            try ageReading(cli, "lab", by: 60)
            let out = try cli.run(["run", "lab"] + flags)
            #expect(out.status == 0, "\(flags)")
            if flags.isEmpty {
                let args = cli.fakeRecord("args.log").split(separator: "\n")
                #expect(args.contains { $0.hasPrefix("--settings ") })
            } else {
                #expect(text(out.stdout).hasPrefix("claude --settings '"))
            }
        }
    }

    @Test func aTokenAccountCompetesAgainOnceARefreshProbesItAndTheProbeWorks() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try rejectedLab(cli)
        #expect(try labInPick(cli).reason == "login rejected")
        try cli.fakeProbe("ok.jsonl")
        #expect(try cli.run(["refresh"]).status == 0)
        let lab = try labInPick(cli)
        #expect(lab.eligible == true && lab.picked == "lab")
    }

    @Test func pickJudgesALoginAccountWhoseProbesRejectionStandsByItsSignInCheck() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        #expect(try cli.run(["refresh"]).status == 0)
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "main", "--force"]).status == 1)
        #expect(try tokenError(cli, "main")?["code"] as? String == "login_rejected")
        // A login account is judged at pick time by `auth status`, which still lists the sign-in.
        let answer = try object(try cli.run(["pick", "--json"]))
        #expect(answer["label"] as? String == "main")
    }

    // MARK: the Fable probe and the sign-in

    /// Turns the Fable probe on, with the fake `claude` answering it from `fixture`.
    func fableAnswers(_ cli: CLIHome, _ fixture: String, capPercentOfWeekly: Int? = nil) throws {
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        var config = try store.loadRequired()
        config.fable.probe = true
        if let capPercentOfWeekly { config.fable.capPercentOfWeekly = capPercentOfWeekly }
        try store.save(config)
        let now = Int(Date().timeIntervalSince1970)
        let reply = try String(
            contentsOf: cli.fixtures.appendingPathComponent("probe/\(fixture)"), encoding: .utf8
        )
        .replacingOccurrences(of: "@RESET_5H@", with: "\(now + 10_000)")
        .replacingOccurrences(of: "@RESET_7D@", with: "\(now + 400_000)")
        try cli.fake("probe-fable.jsonl", reply)
    }

    /// How many probes with `model` the fake `claude` has run under the token file of `label`.
    func tokenProbeRuns(_ cli: CLIHome, _ label: String, model: String) throws -> Int {
        let file = try tokenFile(cli, label)
        return cli.fakeRecord("args.log").split(separator: "\n").filter {
            $0.hasPrefix("-p ") && $0.contains("--model \(model) ")
                && $0.contains("--settings \(file.path)")
        }.count
    }

    /// How many probes with `model` the fake `claude` has run, for any account.
    func probeRuns(_ cli: CLIHome, model: String) -> Int {
        cli.fakeRecord("models.log").split(separator: "\n").filter { String($0) == model }.count
    }

    /// `main` with a fresh reading, then a forced probe that finds its sign-in rejected. The
    /// reading is two minutes old and the status sees it, so a later probe stores a newer one.
    func rejectedMain(_ cli: CLIHome) throws {
        #expect(try cli.run(["refresh"]).status == 0)
        try ageReading(cli, "main", by: 120)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "main", "--force"]).status == 1)
        #expect(try tokenError(cli, "main")?["code"] as? String == "login_rejected")
    }

    @Test func aFablePickWhoseFableProbeIsRejectedSkipsTheTokenAndRecordsTheRejection() throws {
        // Each caller form in a home of its own, so the pick's own Fable probe is the one judged.
        for flags in [["--caller", "launcher"], []] {
            let cli = try setUp()
            defer { cli.cleanup() }
            try addLab(cli)
            try loginLab(cli)
            // With the whole week as Fable room, only the sign-in can keep lab out.
            try fableAnswers(cli, "auth_error.jsonl", capPercentOfWeekly: 100)
            let plain = try tokenProbeRuns(cli, "lab", model: "haiku")
            let lab = try labInPick(cli, ["--model", "fable"] + flags)
            #expect(lab.eligible == false && lab.reason == "login rejected", "\(flags)")
            #expect(lab.picked == nil, "\(flags)")
            // The reading `login` stored is fresh, so the Fable probe was the pick's only probe.
            #expect(try tokenProbeRuns(cli, "lab", model: "fable") == 1, "\(flags)")
            #expect(try tokenProbeRuns(cli, "lab", model: "haiku") == plain, "\(flags)")
            #expect(try tokenError(cli)?["code"] as? String == "login_rejected", "\(flags)")
        }
    }

    @Test func aFablePickSkipsATokenWhosePlainProbeWorkedAndFableProbeWasRejected() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        try ageReading(cli, "lab")
        try fableAnswers(cli, "auth_error.jsonl", capPercentOfWeekly: 100)
        let plain = try tokenProbeRuns(cli, "lab", model: "haiku")
        let lab = try labInPick(cli, ["--model", "fable", "--caller", "launcher"])
        // The aged reading made the pick probe lab plainly, and that probe worked.
        #expect(try tokenProbeRuns(cli, "lab", model: "haiku") == plain + 1)
        #expect(try tokenProbeRuns(cli, "lab", model: "fable") == 1)
        #expect(lab.eligible == false && lab.reason == "login rejected")
        #expect(lab.picked == nil)
        #expect(try tokenError(cli)?["code"] as? String == "login_rejected")
    }

    @Test func aFablePickSkipsALoginAccountWhoseFableProbeIsRejected() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        #expect(try cli.run(["refresh"]).status == 0)
        try fableAnswers(cli, "auth_error.jsonl", capPercentOfWeekly: 100)
        let answer = try object(
            try cli.run(["pick", "--json", "--model", "fable", "--caller", "launcher"]))
        let main = try candidate(answer, "main")
        #expect(probeRuns(cli, model: "fable") == 1)
        #expect(main["eligible"] as? Bool == false)
        #expect(main["reason"] as? String == "login rejected")
        #expect(answer["label"] as? String == nil)
    }

    @Test func aRefreshWhoseFableProbeIsRejectedKeepsTheTokenOutUntilAProbeWorks() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // Still fresh, and older than the reading of the probe that ends the rejection.
        try ageReading(cli, "lab", by: 120)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try fableAnswers(cli, "auth_error.jsonl")
        let plain = try tokenProbeRuns(cli, "lab", model: "haiku")
        let out = try cli.run(["refresh", "--label", "lab"])
        #expect(out.status == 1)
        #expect(text(out.stdout).contains("lab: fable Error login_rejected"))
        #expect(try tokenProbeRuns(cli, "lab", model: "fable") == 1)
        #expect(try tokenProbeRuns(cli, "lab", model: "haiku") == plain)
        let error = try #require(try tokenError(cli))
        #expect(error["code"] as? String == "login_rejected")
        let shown = try #require(error["text"] as? String)

        for flags in [["--caller", "launcher"], []] {
            let lab = try labInPick(cli, flags)
            #expect(lab.eligible == false && lab.reason == "login rejected", "\(flags)")
            #expect(lab.picked == nil, "\(flags)")
        }
        // A reader saves the verdict that `run` relies on.
        _ = try HookRecord(context: ToolContext(home: cli.home, ambient: [:])).readSettings()
        let run = try cli.run(["run", "lab", "--print-command"])
        #expect(run.status == 1)
        #expect(text(run.stderr).contains(shown))
        #expect(try tokenProbeRuns(cli, "lab", model: "haiku") == plain)

        // The rejection stands, so the next refresh probes the fresh reading again.
        #expect(try cli.run(["refresh", "--label", "lab"]).status == 0)
        #expect(try tokenProbeRuns(cli, "lab", model: "haiku") == plain + 1)
        #expect(try tokenError(cli) == nil)
    }

    @Test func aFableProbeThatWorksOverAFreshReadingEndsAStandingRejection() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try rejectedMain(cli)
        try fableAnswers(cli, "fable.jsonl")
        let plain = probeRuns(cli, model: "haiku")
        // `auth status` judges `main` at pick time, so a Fable pick probes its fresh reading with
        // the Fable model alone.
        _ = try cli.run(["pick", "--json", "--model", "fable"])
        #expect(probeRuns(cli, model: "fable") == 1)
        #expect(probeRuns(cli, model: "haiku") == plain)
        #expect(try tokenError(cli, "main") == nil)
    }

    @Test func aFableProbeThatFailsForAnotherReasonLeavesAStandingRejection() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try rejectedMain(cli)
        try fableAnswers(cli, "no_event.jsonl")
        let answer = try object(try cli.run(["pick", "--json", "--model", "fable"]))
        #expect(probeRuns(cli, model: "fable") == 1)
        // Such a failure says nothing on the sign-in, so that pick does not call it a rejection.
        #expect(try candidate(answer, "main")["reason"] as? String != "login rejected")
        #expect(try tokenError(cli, "main")?["code"] as? String == "login_rejected")
    }

    // MARK: a rejection recorded while a pick runs

    /// The candidate entry of `label` in a pick's JSON answer.
    func candidate(_ answer: [String: Any], _ label: String) throws -> [String: Any] {
        let candidates = try #require(answer["candidates"] as? [[String: Any]])
        return try #require(candidates.first { $0["label"] as? String == label })
    }

    /// Dates the stored reading of `label` back, by default an hour, so a pick probes it.
    func ageReading(_ cli: CLIHome, _ label: String, by seconds: TimeInterval = 3600) throws {
        let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
        var reading = try #require(try store.load(label: label))
        reading.readAt = Date().addingTimeInterval(-seconds)
        try store.save(reading, label: label)
    }

    /// The text of a probe fixture as the fake `claude` answers with it.
    func probeAnswer(_ cli: CLIHome, _ fixture: String) throws -> String {
        try String(
            contentsOf: cli.fixtures.appendingPathComponent("probe/\(fixture)"), encoding: .utf8)
    }

    /// `lab` and `spare-a` signed in with fresh readings of their own, and room for a held probe:
    /// no probe timeout or pick deadline ends one before the test lets it go.
    func labAndASpare(_ cli: CLIHome) throws {
        try addLab(cli)
        try loginLab(cli)
        try addLab(cli, "spare-a")
        try cli.fake("probe-for-spare-a.jsonl", try probeText(cli, week: 350_000, five: 5_000))
        try cli.fake("setup-token.out", oauth() + "\n")
        #expect(try cli.run(["login", "spare-a"]).status == 0)
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        var config = try store.loadRequired()
        config.probe.timeoutSeconds = 600
        config.fable.probeTimeoutSeconds = 600
        config.picker.deadlineSeconds = 600
        try store.save(config)
    }

    /// Waits, at most five minutes, until the fake `claude` holds a probe of `label`.
    func heldProbe(_ cli: CLIHome, _ label: String) -> Bool {
        let marker = cli.home.appendingPathComponent(".ab-fake/held-\(label)")
        for _ in 0..<6000 {
            if FileManager.default.fileExists(atPath: marker.path) { return true }
            usleep(50_000)
        }
        return false
    }

    /// A pick that has made its checks before the probes waits on spare-a's held probe while
    /// `refresh` runs `refreshArgs`; then the test lets the probe go. Returns the refresh's exit
    /// code, the row's error code right after it, and the pick's answer.
    func pickAroundARefresh(_ cli: CLIHome, pick pickArgs: [String], refresh refreshArgs: [String])
        throws -> (refresh: Int32, code: String?, answer: [String: Any])
    {
        try cli.fake("hold-spare-a", "")
        defer { try? cli.fake("go-spare-a", "") }
        let pick = Started(cli, pickArgs)
        try #require(heldProbe(cli, "spare-a"))
        let refresh = try cli.run(refreshArgs).status
        let code = try tokenError(cli)?["code"] as? String
        try cli.fake("go-spare-a", "")
        let out = try #require(pick.wait())
        return (refresh, code, try object(out))
    }

    @Test func aPickSkipsATokenWhoseFableProbeARefreshFoundRejectedWhileThePickRan() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        // spare-a's aged reading makes the pick probe it; that probe fails, so only lab can win.
        try ageReading(cli, "spare-a")
        try cli.fake("probe-for-spare-a.jsonl", try probeAnswer(cli, "no_event.jsonl"))
        try fableAnswers(cli, "auth_error.jsonl")
        let plain = try tokenProbeRuns(cli, "lab", model: "haiku")
        // lab's daily Fable probe runs in the refresh, finds the token rejected and is recorded.
        let seen = try pickAroundARefresh(
            cli, pick: ["pick", "--json", "--exclude", "main", "--caller", "launcher"],
            refresh: ["refresh", "--label", "lab"])
        #expect(seen.refresh == 1)
        #expect(seen.code == "login_rejected")
        let lab = try candidate(seen.answer, "lab")
        #expect(lab["eligible"] as? Bool == false)
        #expect(lab["reason"] as? String == "login rejected")
        #expect(seen.answer["label"] as? String == nil)
        #expect(try tokenProbeRuns(cli, "lab", model: "fable") == 1)
        #expect(try tokenProbeRuns(cli, "lab", model: "haiku") == plain)
    }

    @Test func aPickSkipsATokenWhosePlainProbeARefreshFoundRejectedWhileThePickRan() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        // lab's Fable probe is not due; spare-a's is, in this Fable pick, and it is rejected.
        let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
        var reading = try #require(try store.load(label: "lab"))
        reading.fableProbedAt = Date()
        try store.save(reading, label: "lab")
        try fableAnswers(cli, "fable.jsonl", capPercentOfWeekly: 100)
        try cli.fake("probe-for-spare-a.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        let plain = try tokenProbeRuns(cli, "lab", model: "haiku")
        // A forced refresh probes lab's fresh reading, finds the token rejected and records it.
        let seen = try pickAroundARefresh(
            cli,
            pick: [
                "pick", "--json", "--exclude", "main", "--model", "fable", "--caller", "launcher",
            ],
            refresh: ["refresh", "--label", "lab", "--force"])
        #expect(seen.refresh == 1)
        #expect(seen.code == "login_rejected")
        let lab = try candidate(seen.answer, "lab")
        #expect(lab["eligible"] as? Bool == false)
        #expect(lab["reason"] as? String == "login rejected")
        #expect(seen.answer["label"] as? String == nil)
        // The refresh made the only probe of lab.
        #expect(try tokenProbeRuns(cli, "lab", model: "haiku") == plain + 1)
        #expect(try tokenProbeRuns(cli, "lab", model: "fable") == 0)
    }

    @Test func aPickInFlightStillReturnsATokenWhenNoRejectionIsRecordedMeanwhile() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        try ageReading(cli, "spare-a")
        try cli.fake("probe-for-spare-a.jsonl", try probeAnswer(cli, "no_event.jsonl"))
        try fableAnswers(cli, "fable.jsonl")
        // The same order, but lab's Fable probe in the refresh works.
        let seen = try pickAroundARefresh(
            cli, pick: ["pick", "--json", "--exclude", "main", "--caller", "launcher"],
            refresh: ["refresh", "--label", "lab"])
        #expect(seen.refresh == 0)
        #expect(seen.code == nil)
        #expect(try candidate(seen.answer, "lab")["eligible"] as? Bool == true)
        #expect(seen.answer["label"] as? String == "lab")
    }

    @Test func aFablePickThatEndsBusyRecordsItsProbesRejectionSoTheNextPickSkipsTheToken() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        try fableAnswers(cli, "auth_error.jsonl", capPercentOfWeekly: 100)
        let plain = try tokenProbeRuns(cli, "lab", model: "haiku")
        // Another command holds the pick lock for longer than a pick waits for it.
        let writer = NoFollowWriter(root: ToolContext(home: cli.home, ambient: [:]).dataRoot)
        let held = try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 0))
        let busy = try cli.run([
            "pick", "--json", "--exclude", "main", "--model", "fable", "--caller", "launcher",
        ])
        held.release()
        #expect(busy.status == 1)
        #expect(text(busy.stderr).contains("pick busy"))
        #expect(try tokenProbeRuns(cli, "lab", model: "fable") == 1)
        #expect(try tokenError(cli)?["code"] as? String == "login_rejected")
        // The Fable probe is not due again today, so only the record keeps lab out.
        let lab = try labInPick(cli, ["--caller", "launcher"])
        #expect(lab.eligible == false && lab.reason == "login rejected")
        #expect(lab.picked == nil)
        #expect(try tokenProbeRuns(cli, "lab", model: "fable") == 1)
        #expect(try tokenProbeRuns(cli, "lab", model: "haiku") == plain)
    }

    @Test func aPickThatFailsToWriteItsLaunchFileRecordsItsProbesRejection() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        try fableAnswers(cli, "fable.jsonl", capPercentOfWeekly: 100)
        try cli.fake("probe-for-spare-a.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        // A file in the place of lab's launch folder fails the pick once it has chosen lab.
        let root = LaunchFiles.rootURL(context: ToolContext(home: cli.home, ambient: [:]))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let blocker = root.appendingPathComponent("lab")
        try? FileManager.default.removeItem(at: blocker)
        try Data().write(to: blocker)
        let failed = try cli.run([
            "pick", "--json", "--exclude", "main", "--model", "fable", "--caller", "launcher",
        ])
        #expect(failed.status == 1)
        #expect(try tokenProbeRuns(cli, "spare-a", model: "fable") == 1)
        #expect(try tokenError(cli, "spare-a")?["code"] as? String == "login_rejected")
        // The next pick skips spare-a before any probe.
        let next = try object(
            try cli.run([
                "pick", "--json", "--exclude", "main", "--dry-run", "--caller", "launcher",
            ]))
        let spare = try candidate(next, "spare-a")
        #expect(spare["eligible"] as? Bool == false)
        #expect(spare["reason"] as? String == "login rejected")
        #expect(try tokenProbeRuns(cli, "spare-a", model: "fable") == 1)
    }

    // MARK: a refresh that ends in an error

    @Test func aRefreshThatCannotSaveAPlanStillRecordsItsProbesRejection() throws {
        // lab's plain probe in a forced refresh, then its daily Fable probe over a fresh reading.
        for forced in [true, false] {
            let cli = try setUp()
            defer { cli.cleanup() }
            try addLab(cli)
            try loginLab(cli)
            try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
            if !forced { try fableAnswers(cli, "fable.jsonl") }
            // main's first placed check gives a plan to save, and the data folder takes no new file.
            let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
            var config = try store.loadRequired()
            let main = try #require(config.accounts.firstIndex { $0.label == "main" })
            config.accounts[main].expectedPlanTier = nil
            try store.save(config)
            let root = cli.dataRoot.path
            func mode(_ value: Int) throws {
                try FileManager.default.setAttributes(
                    [.posixPermissions: value], ofItemAtPath: root)
            }
            let model = forced ? "haiku" : "fable"
            let probes = try tokenProbeRuns(cli, "lab", model: model)
            try mode(0o500)
            defer { try? mode(0o700) }
            let out = try cli.run(["refresh"] + (forced ? ["--force"] : []))
            try mode(0o700)
            #expect(out.status == 1, "\(forced)")
            #expect(text(out.stderr).contains("Could not write config.json."), "\(forced)")
            #expect(try tokenProbeRuns(cli, "lab", model: model) == probes + 1, "\(forced)")
            #expect(try tokenError(cli)?["code"] as? String == "login_rejected", "\(forced)")
            let lab = try labInPick(cli, ["--caller", "launcher"])
            #expect(lab.eligible == false && lab.reason == "login rejected", "\(forced)")
            #expect(lab.picked == nil, "\(forced)")
        }
    }

    // MARK: a working probe recorded after a newer rejection

    /// The pick lock, held by the test until it lets it go.
    func holdPickLock(_ cli: CLIHome) throws -> FileLock {
        let writer = NoFollowWriter(root: ToolContext(home: cli.home, ambient: [:]).dataRoot)
        return try #require(
            try writer.acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 0))
    }

    /// True while `state/current.json` records a probe's rejection of lab, read with no rebuild.
    func labRejectionRecorded(_ cli: CLIHome) throws -> Bool {
        let context = ToolContext(home: cli.home, ambient: [:])
        let lab = try #require(try ConfigStore(context: context).loadRequired().account("lab"))
        return StatusBuilder.probeRejection(context: context, account: lab) != nil
    }

    /// The time of lab's stored reading.
    func labReadAt(_ cli: CLIHome) throws -> Date {
        let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
        return try #require(try store.load(label: "lab")).readAt
    }

    /// Waits, at most five minutes, until lab's stored reading is newer than `time`.
    func labReadingStored(_ cli: CLIHome, after time: Date) -> Bool {
        let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
        for _ in 0..<6000 {
            if let reading = try? store.load(label: "lab"), reading.readAt > time { return true }
            usleep(50_000)
        }
        return false
    }

    /// A launcher pick probes lab's aged reading, the probe works, and the pick then waits for
    /// the pick lock the test holds; meanwhile a forced refresh finds lab's token rejected and
    /// records it. Then the test lets the lock go, or with `busy` the pick waits it out. Returns
    /// the refresh's exit code, whether the rejection was recorded while the pick still ran, and
    /// the pick's output.
    func rejectionWhileAPickWaits(_ cli: CLIHome, busy: Bool) throws
        -> (refresh: Int32, recorded: Bool, pick: Support.Output)
    {
        try addLab(cli)
        try loginLab(cli)
        try ageReading(cli, "lab")
        let aged = try labReadAt(cli)
        let lock = try holdPickLock(cli)
        var held = true
        defer { if held { lock.release() } }
        let pick = Started(cli, ["pick", "--json", "--exclude", "main", "--caller", "launcher"])
        // The pick's own probe of lab stored its reading, so the rejection's status sees it.
        try #require(labReadingStored(cli, after: aged))
        try cli.fakeProbe("auth_error.jsonl")
        let refresh = try cli.run(["refresh", "--label", "lab", "--force"]).status
        let recorded = try labRejectionRecorded(cli) && !pick.hasEnded
        if !busy {
            lock.release()
            held = false
        }
        return (refresh, recorded, try #require(pick.wait()))
    }

    /// lab's row keeps `login_rejected`, and the next launcher pick skips lab before any probe.
    func expectLabRejectionStands(_ cli: CLIHome) throws {
        #expect(try labRejectionRecorded(cli))
        let probes = try tokenProbeRuns(cli, "lab")
        #expect(try tokenError(cli)?["code"] as? String == "login_rejected")
        let lab = try labInPick(cli, ["--caller", "launcher"])
        #expect(lab.eligible == false && lab.reason == "login rejected")
        #expect(lab.picked == nil)
        #expect(try tokenProbeRuns(cli, "lab") == probes)
    }

    @Test func aPicksOlderWorkingProbeLeavesARejectionRecordedWhileItWaitedForTheLock() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let seen = try rejectionWhileAPickWaits(cli, busy: false)
        #expect(seen.refresh == 1)
        #expect(seen.recorded)
        // Under the lock the pick reads the rejection again and skips lab.
        #expect(seen.pick.status == 2)
        let answer = try object(seen.pick)
        #expect(try candidate(answer, "lab")["reason"] as? String == "login rejected")
        #expect(answer["label"] as? String == nil)
        try expectLabRejectionStands(cli)
    }

    @Test func aPickThatEndsBusyLeavesARejectionNewerThanItsWorkingProbe() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let seen = try rejectionWhileAPickWaits(cli, busy: true)
        #expect(seen.refresh == 1)
        #expect(seen.recorded)
        #expect(seen.pick.status == 1)
        #expect(text(seen.pick.stderr).contains("pick busy"))
        try expectLabRejectionStands(cli)
    }

    @Test func aPicksWorkingProbeNewerThanARejectionEndsItAfterWaitingForTheLock() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // The rejection's status sees a reading two hours old.
        try ageReading(cli, "lab", by: 7200)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        // Another command's probe worked and stored a newer reading, an hour old, before it
        // rebuilt the status, so lab competes again and the pick probes it.
        try ageReading(cli, "lab")
        let older = try labReadAt(cli)
        try cli.fakeProbe("ok.jsonl")
        let lock = try holdPickLock(cli)
        var held = true
        defer { if held { lock.release() } }
        let pick = Started(cli, ["pick", "--json", "--exclude", "main", "--caller", "launcher"])
        try #require(labReadingStored(cli, after: older))
        #expect(try labRejectionRecorded(cli) && !pick.hasEnded)
        lock.release()
        held = false
        let out = try #require(pick.wait())
        #expect(out.status == 0)
        #expect(try object(out)["label"] as? String == "lab")
        #expect(try labRejectionRecorded(cli) == false)
        #expect(try tokenError(cli) == nil)
    }

    @Test func aWorkingProbesReadingEndsARejectionAsSoonAsItsRefreshRecordsIt() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        // The rejection's status sees a reading two minutes old.
        try ageReading(cli, "lab", by: 120)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        let seen = try labReadAt(cli)
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        try #require(try labRejectionRecorded(cli))
        // Signed in again: the refresh records lab's working probe while spare-a's is still held.
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        try ageReading(cli, "spare-a")
        try cli.fake("hold-spare-a", "")
        defer { try? cli.fake("go-spare-a", "") }
        let spareEnds = probeEnds(cli, "spare-a")
        let refresh = Started(cli, ["refresh"])
        try #require(labReadingStored(cli, after: seen))
        try #require(heldProbe(cli, "spare-a"))
        try #require(pollUntil { (try? labRejectionRecorded(cli)) == false })
        #expect(probeEnds(cli, "spare-a") == spareEnds)
        #expect(!refresh.hasEnded)
        // The menu's rebuild each minute sees lab's new reading too and keeps it that way.
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        #expect(try labRejectionRecorded(cli) == false)
        try cli.fake("go-spare-a", "")
        let out = try #require(refresh.wait())
        #expect(out.status == 0)
        #expect(try labRejectionRecorded(cli) == false)
        #expect(try tokenError(cli) == nil)
        let lab = try labInPick(cli, ["--exclude", "spare-a"])
        #expect(lab.eligible == true && lab.picked == "lab")
    }

    @Test func aPlainRefreshStartsNoProbeOnceAnotherRebuildSawAWorkingProbesNewerReading() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        // The rejection's status sees a reading two minutes old.
        try ageReading(cli, "lab", by: 120)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        let seen = try labReadAt(cli)
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        try #require(try labRejectionRecorded(cli))
        // A refresh's probe of lab works and stores a newer reading, and the menu's rebuild sees
        // it while that refresh waits on spare-a's held probe.
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        try ageReading(cli, "spare-a")
        try cli.fake("hold-spare-a", "")
        defer { try? cli.fake("go-spare-a", "") }
        let refresh = Started(cli, ["refresh"])
        try #require(labReadingStored(cli, after: seen))
        try #require(heldProbe(cli, "spare-a"))
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        try cli.fake("go-spare-a", "")
        #expect(try #require(refresh.wait()).status == 0)
        // Every reading is fresh, so a plain refresh starts no probe, lab's included.
        let probes = probeRuns(cli, model: "haiku")
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probeRuns(cli, model: "haiku") == probes)
        #expect(try labRejectionRecorded(cli) == false)
    }

    // MARK: a stored reading the rejection's rebuild cannot read

    /// The time `state/current.json` keeps with lab's standing probe rejection, read with no
    /// rebuild.
    func labRejectionTime(_ cli: CLIHome) throws -> Date? {
        let context = ToolContext(home: cli.home, ambient: [:])
        let lab = try #require(try ConfigStore(context: context).loadRequired().account("lab"))
        return StatusBuilder.probeRejection(context: context, account: lab)
    }

    @Test func aRejectionStandsOverAStoredReadingItsRebuildCouldNotRead() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        // An hour old, so the first refresh probes lab; the status sees that reading.
        try ageReading(cli, "lab")
        try ageReading(cli, "spare-a")
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        let seen = try labReadAt(cli)
        // The first refresh records lab's working probe at once, then waits on spare-a's held one.
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        try cli.fake("hold-spare-a", "")
        defer { try? cli.fake("go-spare-a", "") }
        let spareEnds = probeEnds(cli, "spare-a")
        let first = Started(cli, ["refresh"])
        try #require(labReadingStored(cli, after: seen))
        try #require(heldProbe(cli, "spare-a"))
        let stored = try labReadAt(cli)
        try #require(pollUntil { (try? recordedEntry(cli, "lab"))?.lastReadingAt == stored })
        try #require(probeEnds(cli, "spare-a") == spareEnds)
        // A forced refresh reads that reading and its probe is held; the reading then cannot be
        // read until the probe's rejection is recorded.
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        try cli.fake("hold-lab", "")
        defer { try? cli.fake("go-lab", "") }
        let second = Started(cli, ["refresh", "--label", "lab", "--force"])
        try #require(heldProbe(cli, "lab"))
        let file = cli.dataRoot.appendingPathComponent("state/readings/lab.json").path
        try #require(chmod(file, 0) == 0)
        defer { chmod(file, 0o600) }
        #expect(throws: (any Error).self) {
            try ReadingStore(context: ToolContext(home: cli.home, ambient: [:])).load(label: "lab")
        }
        try cli.fake("go-lab", "")
        #expect(try #require(second.wait()).status == 1)
        #expect(chmod(file, 0o600) == 0)
        // The rejection is dated no earlier than the reading stored before it.
        let rejectedAt = try #require(try labRejectionTime(cli))
        #expect(rejectedAt >= stored)
        // The menu's rebuild reads that reading, then the first refresh ends; the rejection stands.
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        #expect(try labRejectionRecorded(cli))
        try cli.fake("go-spare-a", "")
        #expect(try #require(first.wait()).status == 0)
        #expect(try labRejectionRecorded(cli))
        let probes = try tokenProbeRuns(cli, "lab")
        let skipped = try labInPick(cli, ["--caller", "launcher", "--exclude", "spare-a"])
        #expect(skipped.eligible == false && skipped.reason == "login rejected")
        #expect(skipped.picked == nil)
        #expect(try tokenProbeRuns(cli, "lab") == probes)

        // Signed in again: an older reading keeps the rejection's time, and a later probe ends it.
        let dated = try #require(try labRejectionTime(cli))
        try ageReading(cli, "lab", by: 120)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        #expect(try labRejectionRecorded(cli))
        #expect(try labRejectionTime(cli) == dated)
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        let later = dated.addingTimeInterval(1)
        let probed = try probeLab(cli, at: later)
        try rebuild(cli, [probed], at: later)
        #expect(try tokenProbeRuns(cli, "lab") == probes + 1)
        #expect(try labRejectionRecorded(cli) == false)
        let back = try labInPick(cli, ["--caller", "launcher", "--exclude", "spare-a"])
        #expect(back.eligible == true && back.picked == "lab")
    }

    /// How lab's stored reading is kept from the rejection's rebuild: the file is moved out of
    /// its folder, the readings folder is moved, or the file is replaced by one that does not
    /// decode. Each is undone by moving the original back.
    enum ReadingGone: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case moveAway, folderMoveAway, garbage
        var testDescription: String { rawValue }
    }

    @Test(arguments: ReadingGone.allCases)
    func aRejectionStandsOverAStoredReadingGoneOrUndecodableAtItsRebuild(form: ReadingGone)
        throws
    {
        let cli = try setUp()
        defer { cli.cleanup() }
        try labAndASpare(cli)
        // A fresh reading keeps main out of the first refresh's probes, so no reading save lands
        // in the readings folder while it is moved away below.
        #expect(try cli.run(["refresh", "--label", "main"]).status == 0)
        // An hour old, so the first refresh probes lab; the status sees that reading.
        try ageReading(cli, "lab")
        try ageReading(cli, "spare-a")
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        let seen = try labReadAt(cli)
        // The first refresh records lab's working probe at once, then waits on spare-a's held one.
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        try cli.fake("hold-spare-a", "")
        defer { try? cli.fake("go-spare-a", "") }
        let spareEnds = probeEnds(cli, "spare-a")
        let first = Started(cli, ["refresh"])
        try #require(labReadingStored(cli, after: seen))
        try #require(heldProbe(cli, "spare-a"))
        let stored = try labReadAt(cli)
        try #require(pollUntil { (try? recordedEntry(cli, "lab"))?.lastReadingAt == stored })
        try #require(probeEnds(cli, "spare-a") == spareEnds)
        // A forced refresh reads that reading and its probe is held; the reading is then gone, or
        // does not decode, until the probe's rejection is recorded.
        try cli.fake("probe-for-lab.jsonl", try probeAnswer(cli, "auth_error.jsonl"))
        try cli.fake("hold-lab", "")
        defer { try? cli.fake("go-lab", "") }
        let second = Started(cli, ["refresh", "--label", "lab", "--force"])
        try #require(heldProbe(cli, "lab"))
        let readings = cli.dataRoot.appendingPathComponent("state/readings")
        let file = readings.appendingPathComponent("lab.json")
        let moved = form == .folderMoveAway ? readings : file
        let aside = cli.home.appendingPathComponent("away-" + moved.lastPathComponent)
        try #require(rename(moved.path, aside.path) == 0)
        var away = true
        defer { if away { rename(aside.path, moved.path) } }
        if form == .garbage {
            try #require(
                FileManager.default.createFile(
                    atPath: file.path, contents: Data("not a reading\n".utf8),
                    attributes: [.posixPermissions: 0o600]))
        }
        try cli.fake("go-lab", "")
        #expect(try #require(second.wait()).status == 1)
        try #require(rename(aside.path, moved.path) == 0)
        away = false
        #expect(try labReadAt(cli) == stored)
        // The rejection is dated no earlier than the reading stored before it.
        let rejectedAt = try #require(try labRejectionTime(cli))
        #expect(rejectedAt >= stored)
        // The menu's rebuild reads it again, then the first refresh ends; the rejection stands.
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        #expect(try labRejectionRecorded(cli))
        try cli.fake("go-spare-a", "")
        #expect(try #require(first.wait()).status == 0)
        #expect(try labRejectionRecorded(cli))
        // The launcher pick and the typed pick skip lab before any probe, and `run` refuses it.
        let probes = try tokenProbeRuns(cli, "lab")
        for flags in [["--caller", "launcher"], []] {
            let lab = try labInPick(cli, flags + ["--exclude", "spare-a"])
            #expect(lab.eligible == false && lab.reason == "login rejected", "\(flags)")
            #expect(lab.picked == nil, "\(flags)")
        }
        let run = try cli.run(["run", "lab", "--print-command"])
        #expect(run.status == 1)
        #expect(text(run.stderr).contains(Messages.probeLoginRejected))
        #expect(try tokenProbeRuns(cli, "lab") == probes)

        // Signed in again: an older reading keeps the rejection's time, and a later probe ends it.
        let dated = try #require(try labRejectionTime(cli))
        try ageReading(cli, "lab", by: 120)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        #expect(try labRejectionRecorded(cli))
        #expect(try labRejectionTime(cli) == dated)
        try cli.fake("probe-for-lab.jsonl", try probeText(cli, week: 450_000, five: 15_000))
        let later = dated.addingTimeInterval(1)
        let probed = try probeLab(cli, at: later)
        try rebuild(cli, [probed], at: later)
        #expect(try tokenProbeRuns(cli, "lab") == probes + 1)
        #expect(try labRejectionRecorded(cli) == false)
        let back = try labInPick(cli, ["--caller", "launcher", "--exclude", "spare-a"])
        #expect(back.eligible == true && back.picked == "lab")
    }

    @Test func aDeletedOrWidenedTokenFileIsTokenMissing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fake("setup-token.out", oauth() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        let file = try tokenFile(cli, "lab")
        let good = try Data(contentsOf: file)
        let text = "No token saved. Run `agent-balancer login lab` in Terminal."
        let cases: [(String, () throws -> Void)] = [
            (
                "widened",
                {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o644], ofItemAtPath: file.path)
                }
            ),
            ("deleted", { try FileManager.default.removeItem(at: file) }),
            (
                "unparsable",
                {
                    try "not json".write(to: file, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            ),
        ]
        for (name, breakIt) in cases {
            try good.write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            try breakIt()
            _ = try cli.run(["status", "--json"])
            var error = try row(cli, "lab")["error"] as? [String: Any]
            #expect(error?["code"] as? String == "token_missing", "\(name)")
            #expect(error?["text"] as? String == text, "\(name)")
            // The background refresh runs the same check; its text must not replace this one.
            let out = try cli.run(["refresh", "--label", "lab", "--force"])
            #expect(out.status == 1, "\(name)")
            #expect(
                String(decoding: out.stdout, as: UTF8.self).contains(
                    "lab: Error token_missing: \(text)"), "\(name)")
            error = try row(cli, "lab")["error"] as? [String: Any]
            #expect(error?["code"] as? String == "token_missing", "\(name)")
            #expect(error?["text"] as? String == text, "\(name)")
        }
    }

    func tokenError(_ cli: CLIHome, _ label: String = "lab") throws -> [String: Any]? {
        _ = try cli.run(["status", "--json"])
        return try row(cli, label)["error"] as? [String: Any]
    }

    func loginLab(_ cli: CLIHome) throws {
        try cli.fake("setup-token.out", oauth() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
    }

    @Test func invalidTokenFileContentIsTokenMissingWithTheLoginText() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        let file = try tokenFile(cli, "lab")
        let bad = [
            "not json at all", "[1,2]", "{}", "{\"env\":{}}", "{\"env\":{\"X\":\"y\"}}",
            "{\"env\":\"text\"}", "",
        ]
        for content in bad {
            try content.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            let error = try tokenError(cli)
            #expect(error?["code"] as? String == "token_missing", "content: \(content)")
            #expect(
                error?["text"] as? String
                    == "No token saved. Run `agent-balancer login lab` in Terminal.",
                "content: \(content)")
        }
    }

    @Test func tokenMissingAppendsOneErrorEventAndRecoversAfterANewLogin() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        func kinds() throws -> [String] {
            try events(cli, label: "lab").compactMap { $0["type"] as? String }
                .filter { $0 == "error" || $0 == "recovered" }
        }
        // The account has been through add (no token: error) and login (recovered).
        _ = try cli.run(["status", "--json"])
        let before = try kinds()
        #expect(before == ["error", "recovered"])
        try FileManager.default.removeItem(at: try tokenFile(cli, "lab"))
        _ = try tokenError(cli)
        _ = try tokenError(cli)
        #expect(try kinds() == before + ["error"])
        let last = try #require(try events(cli, type: "error", label: "lab").last)
        #expect(last["code"] as? String == "token_missing")
        try loginLab(cli)
        _ = try cli.run(["status", "--json"])
        #expect(try kinds() == before + ["error", "recovered"])
        #expect(try row(cli, "lab")["error"] == nil || row(cli, "lab")["error"] is NSNull)
    }

    @Test func pickSkipsATokenMissingAccountAndUnskipsItAfterLogin() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        func lab() throws -> [String: Any] {
            let out = try cli.run(["pick", "--dry-run", "--json"])
            #expect(out.status == 0)
            let list = try #require(try object(out)["candidates"] as? [[String: Any]])
            return try #require(list.first { $0["label"] as? String == "lab" })
        }
        #expect(try lab()["eligible"] as? Bool == true)
        let file = try tokenFile(cli, "lab")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        var skipped = try lab()
        #expect(skipped["eligible"] as? Bool == false)
        #expect(skipped["reason"] as? String == "no token saved")
        try FileManager.default.removeItem(at: file)
        skipped = try lab()
        #expect(skipped["eligible"] as? Bool == false)
        #expect(skipped["reason"] as? String == "no token saved")
        for content in ["{}", "not json", "{\"env\":{}}"] {
            try content.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            skipped = try lab()
            #expect(skipped["eligible"] as? Bool == false, "content: \(content)")
            #expect(skipped["reason"] as? String == "no token saved", "content: \(content)")
        }
        try FileManager.default.removeItem(at: file)
        try loginLab(cli)
        #expect(try lab()["eligible"] as? Bool == true)
    }

    @Test func refreshNeverProbesATokenFileThatDoesNotParse() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        let file = try tokenFile(cli, "lab")
        func probes() -> Int {
            cli.fakeRecord("args.log").split(separator: "\n").filter {
                $0.hasPrefix("-p ") && $0.contains("--settings \(file.path)")
            }.count
        }
        #expect(probes() == 1)
        for content in ["not json", "{}", "{\"env\":{}}"] {
            try content.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            let out = try cli.run(["refresh", "--label", "lab", "--force"])
            #expect(out.status == 1, "content: \(content)")
            #expect(probes() == 1, "content: \(content)")
            #expect(
                text(out.stdout).contains(
                    "lab: Error token_missing: No token saved. Run `agent-balancer login lab` in Terminal."
                ), "content: \(content)")
            let error = try #require(try row(cli, "lab")["error"] as? [String: Any])
            #expect(error["code"] as? String == "token_missing", "content: \(content)")
            #expect(
                error["text"] as? String
                    == "No token saved. Run `agent-balancer login lab` in Terminal.",
                "content: \(content)")
        }
    }

    @Test func refreshProbesAgainATokenAccountWhoseLastProbeFoundItsSignInRejected() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // Still fresh, and older than the reading of the probe that ends the rejection.
        try ageReading(cli, "lab", by: 120)
        #expect(try cli.run(["status", "--cached", "--json"]).status == 0)
        let file = try tokenFile(cli, "lab")
        func probes() -> Int {
            cli.fakeRecord("args.log").split(separator: "\n").filter {
                $0.hasPrefix("-p ") && $0.contains("--settings \(file.path)")
            }.count
        }
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        #expect(try tokenError(cli)?["code"] as? String == "login_rejected")

        // The reading `login` stored is still fresh, so only the rejection starts this probe.
        try cli.fakeProbe("ok.jsonl")
        let before = probes()
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(probes() == before + 1)
        #expect(try row(cli, "lab")["error"] is NSNull)
    }

    @Test func aTokenAccountsProbeRejectionStandsWhenTheNextProbeFailsForAnotherReason() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        try cli.fakeProbe("auth_error.jsonl")
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        try cli.fakeProbe("no_event.jsonl")
        #expect(try cli.run(["refresh", "--label", "lab", "--force"]).status == 1)
        #expect(try tokenError(cli)?["code"] as? String == "login_rejected")
    }

    // MARK: the paste prompt on a terminal

    @Test func thePastePromptDoesNotEchoTheToken() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        var master: Int32 = -1
        var slave: Int32 = -1
        #expect(openpty(&master, &slave, nil, nil, nil) == 0)
        defer {
            close(master)
            close(slave)
        }
        let task = Process()
        task.executableURL = cli.exe
        task.arguments = ["login", "lab", "--paste"]
        task.environment = ["HOME": cli.home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        task.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        try task.run()
        // The prompt is printed once echo is off; type only after it shows.
        var shown = Data()
        while !String(decoding: shown, as: UTF8.self).contains("Paste the token") {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            shown.append(chunk)
        }
        let token = oauth()
        let line = Array((token + "\n").utf8)
        #expect(Darwin.write(master, line, line.count) == line.count)
        task.waitUntilExit()
        #expect(task.terminationStatus == 0)
        // Whatever the terminal echoed comes back on the controlling side.
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        var echoed = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let n = read(master, &buffer, buffer.count)
            if n <= 0 { break }
            echoed.append(contentsOf: buffer[0..<n])
        }
        #expect(!String(decoding: echoed, as: UTF8.self).contains(token))
        #expect(try String(contentsOf: try tokenFile(cli, "lab"), encoding: .utf8).contains(token))
    }

    // MARK: the email is a note

    @Test func theEmailIsANoteAndATokensEmailIsNeverClaimed() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        #expect(try cli.run(["add", "lab", "--email", "lab@example.com"]).status == 0)
        try loginLab(cli)
        // The probe stream names someone@example.com; the token account never takes it on.
        let shown = try row(cli, "lab")
        #expect(shown["email"] as? String == "lab@example.com")
        #expect(shown["error"] == nil || shown["error"] is NSNull)
        #expect(try cli.run(["config", "set", "lab", "email", "other@example.com"]).status == 0)
        #expect(try row(cli, "lab")["email"] as? String == "other@example.com")
        var seen = ""
        for args in [
            ["status", "--json"], ["doctor"], ["config", "show", "--emails"], ["events", "--json"],
            ["history", "--json"], ["refresh", "--label", "lab", "--force"],
        ] {
            let out = try cli.run(args)
            seen += text(out.stdout) + text(out.stderr)
        }
        seen += nonTokenText(cli)
        #expect(!seen.contains("someone@example.com"))
        #expect(!seen.contains("wrong_account"))
    }

    // MARK: end rules on a token account

    @Test func configSetEndsAndEndingSoonWorkOnATokenAccount() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        func lab() throws -> [String: Any] {
            try #require(try config(cli).first { $0["label"] as? String == "lab" })
        }
        #expect(try cli.run(["config", "set", "lab", "ends", "2099-12-31"]).status == 0)
        #expect(try lab()["kind"] as? String == "token")
        #expect(try lab()["endsAt"] as? String == "2099-12-31")
        #expect(try lab()["endingSoon"] == nil)
        var shown = try row(cli, "lab")
        #expect(shown["endsAt"] as? String == "2099-12-31")
        #expect(shown["endingSoon"] as? Bool == false)
        var show = text(try cli.run(["config", "show"]).stdout)
        #expect(show.contains("account lab\n  kind: token\n  role: pool\n  ends: 2099-12-31\n"))
        // One end marker: the soon flag takes the date's place.
        let soon = try cli.run(["config", "set", "lab", "ending-soon", "true"])
        #expect(soon.status == 0)
        #expect(text(soon.stdout).contains("Also cleared ends: an account keeps one end marker."))
        #expect(try lab()["endsAt"] == nil)
        #expect(try lab()["endingSoon"] as? Bool == true)
        shown = try row(cli, "lab")
        #expect(shown["endsAt"] is NSNull)
        #expect(shown["endingSoon"] as? Bool == true)
        show = text(try cli.run(["config", "show"]).stdout)
        #expect(show.contains("  ending-soon: true"))
        #expect(!show.contains("  ends: "))

        let today = Self.localDay(Date())
        #expect(try cli.run(["config", "set", "lab", "ends", today]).status == 0)
        #expect(try lab()["endsAt"] as? String == today)
        #expect(try cli.run(["config", "set", "lab", "ends", "2020-01-01"]).status == 1)
        #expect(try lab()["endsAt"] as? String == today)
        #expect(try cli.run(["config", "set", "lab", "ends", "none"]).status == 0)
        #expect(try cli.run(["config", "set", "lab", "ending-soon", "false"]).status == 0)
        #expect(try lab()["endsAt"] == nil && lab()["endingSoon"] == nil)
    }

    @Test func configSetLabelRefusesATokenAccountAndWritesNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        #expect(try cli.run(["pick", "--json"]).status == 0)
        func snapshot() -> [String: Data] {
            var files: [String: Data] = [:]
            for url in cli.dataEntries() {
                files[url.path] = (try? Data(contentsOf: url)) ?? Data()
            }
            return files
        }
        let before = snapshot()
        let out = try cli.run(["config", "set", "lab", "label", "renamed"])
        #expect(out.status == 1)
        let message = text(out.stderr)
        #expect(message.contains("A token account cannot be renamed."))
        #expect(message.contains("agent-balancer remove lab"))
        #expect(message.contains("agent-balancer add renamed"))
        #expect(!message.contains(oauth()))
        #expect(snapshot() == before)
        #expect(try config(cli).contains { $0["label"] as? String == "lab" })
        #expect(!FileManager.default.fileExists(atPath: try tokenFile(cli, "renamed").path))
        // A login account still renames.
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
    }

    enum EndRule: CaseIterable {
        case none, endingSoon, endsToday
    }

    func setEndRule(_ cli: CLIHome, _ label: String, _ rule: EndRule) throws {
        let ends = rule == .endsToday ? Self.localDay(Date()) : "none"
        let soon = rule == .endingSoon ? "true" : "false"
        #expect(try cli.run(["config", "set", label, "ends", ends]).status == 0)
        #expect(try cli.run(["config", "set", label, "ending-soon", soon]).status == 0)
    }

    /// The label a dry-run pick returns, and its reason. A dry run writes no lease, so the room of
    /// each account stays the same from one pick to the next.
    func dryPick(_ cli: CLIHome) throws -> (label: String?, reason: String) {
        let doc = try object(try cli.run(["pick", "--dry-run", "--json"]))
        return (doc["label"] as? String, doc["reason"] as? String ?? "")
    }

    @Test func pickRanksATokenAccountByTheSameEndRulesAsALoginAccount() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        // Both accounts read the same probe stream, so only the end rules tell them apart.
        let store = ConfigStore(context: ToolContext(home: cli.home, ambient: [:]))
        let candidates = try #require(
            try object(try cli.run(["pick", "--dry-run", "--json"]))["candidates"]
                as? [[String: Any]])
        #expect(candidates.allSatisfy { $0["eligible"] as? Bool == true })

        // The winner by position for each pair of rules, the first account then the second.
        // Run once with the login account first and once with the token account first: the
        // same rules must give the same position whatever the kind.
        var answers: [[Int]] = []
        for order in [["main", "lab"], ["lab", "main"]] {
            var registry = try store.loadRequired()
            registry.accounts.sort {
                (order.firstIndex(of: $0.label) ?? 9) < (order.firstIndex(of: $1.label) ?? 9)
            }
            try store.save(registry)
            var row: [Int] = []
            for firstRule in EndRule.allCases {
                for secondRule in EndRule.allCases {
                    try setEndRule(cli, order[0], firstRule)
                    try setEndRule(cli, order[1], secondRule)
                    let (label, reason) = try dryPick(cli)
                    let position = try #require(label.flatMap { order.firstIndex(of: $0) })
                    row.append(position)
                    let rule = position == 0 ? firstRule : secondRule
                    #expect(
                        reason.contains(rule == .none ? "weekly reset" : "Soonest expiry: ends"),
                        "\(order) \(firstRule) \(secondRule): \(reason)")
                }
            }
            answers.append(row)
        }
        #expect(answers[0] == answers[1])
        // none/none, then an ending-soon or ending-today second account goes first, and a known
        // end today beats the ending-soon assumption of two days.
        #expect(answers[0] == [0, 1, 1, 0, 0, 1, 0, 0, 0])

        // An ended account is skipped, whatever its kind.
        for label in ["main", "lab"] {
            try setEndRule(cli, "main", .none)
            try setEndRule(cli, "lab", .none)
            var registry = try store.loadRequired()
            if let index = registry.accounts.firstIndex(where: { $0.label == label }) {
                registry.accounts[index].endsAt = "2000-01-01"
            }
            try store.save(registry)
            let doc = try object(try cli.run(["pick", "--dry-run", "--json"]))
            let list = try #require(doc["candidates"] as? [[String: Any]])
            let ended = try #require(list.first { $0["label"] as? String == label })
            #expect(ended["eligible"] as? Bool == false)
            #expect(ended["reason"] as? String == "account ended")
            #expect(doc["label"] as? String != label)
        }
    }

    // MARK: the architecture text

    @Test func theArchitectureStatesWhereATokenMayBe() throws {
        let doc = try String(
            contentsOf: Support.root.appendingPathComponent("docs/ARCHITECTURE.md"),
            encoding: .utf8)
        let start = try #require(doc.range(of: "Where a token may be:"))
        let paragraph = doc[start.lowerBound...].prefix { $0 != "#" }
        for place in [
            "the token file, the launch files of that label, and nowhere else", "stdout", "stderr",
            "`status`", "`events`", "`history`", "`picks.log`", "the log", "an argument",
            "an environment the tool builds",
        ] {
            #expect(paragraph.contains(place), "\(place)")
        }
    }

    // MARK: leak test, the setup-token shape

    /// The only places a token of `label` may sit, as patterns on a file's path: its token file
    /// and its own launch files, `l-<8 hex>.json`, directly in its launch folder. A writer's
    /// temporary file, another label's file or anything else is a leak.
    static func tokenHomes(dataFolder: String, label: String) -> [String] {
        let tokens = TokenPaths.folders[0]
        let launch = LaunchFiles.rootURL(
            context: ToolContext(home: URL(fileURLWithPath: "/"), ambient: [:])
        )
        .lastPathComponent
        let data = NSRegularExpression.escapedPattern(for: dataFolder)
        return [
            "/\(data)/\(tokens)/\(label)\\.json\\z",
            "/\(data)/\(launch)/\(label)/l-[0-9a-f]{8}\\.json\\z",
        ]
    }

    @Test func aTokenMayOnlySitInItsTokenFileAndItsOwnLaunchFiles() {
        let tokens = TokenPaths.folders[0]
        let launch = LaunchFiles.rootURL(
            context: ToolContext(home: URL(fileURLWithPath: "/"), ambient: [:])
        )
        .lastPathComponent
        let canary = Canary.all()[0]
        let root = "/h/.agent-balancer"
        let allowed = ["\(root)/\(tokens)/lab.json", "\(root)/\(launch)/lab/l-0123abcd.json"]
        let refused = [
            "\(root)/\(tokens)/.tmp-0123456789abcdef",
            "\(root)/\(launch)/lab/.tmp-0123456789abcdef",
            "\(root)/\(tokens)/other.json", "\(root)/\(launch)/other/l-0123abcd.json",
            "\(root)/\(tokens)/lab.json.bak", "\(root)/\(launch)/lab/l-0123abcd.json.old",
            "\(root)/\(launch)/lab/notes.json", "\(root)/state/readings/lab.json",
        ]
        var collected = Collected()
        for path in allowed + refused { collected.streams[path] = Data(canary.value.utf8) }
        let leaks = collected.leaks(
            of: [canary],
            allowedPathPatterns: Self.tokenHomes(dataFolder: ".agent-balancer", label: "lab"))
        #expect(leaks == refused.sorted())
    }

    /// Runs one command and adds everything it and the earlier commands left behind to `collected`.
    func runAndCollect(
        _ cli: CLIHome, _ args: [String], stdin: String? = nil, into leaks: inout [String],
        canaries: [Canary], allowed: [String]
    ) throws -> Support.Output {
        let out = try cli.run(args, stdin: stdin)
        var collected = Collected()
        let name = args.prefix(2).joined(separator: " ")
        collected.streams["stdout of \(name)"] = out.stdout
        collected.streams["stderr of \(name)"] = out.stderr
        try collected.addFiles(under: cli.home)
        // The fake's inputs hold the canary on purpose; its records of what it was given must not.
        let records = ["args.log", "env-full.txt", "env-names.txt", "config-dir.txt", "models.log"]
        for key in collected.streams.keys where key.contains("/.ab-fake/") {
            if !records.contains(where: { key.hasSuffix("/\($0)") }) {
                collected.streams[key] = nil
            }
        }
        leaks += collected.leaks(of: canaries, allowedPathPatterns: allowed).map {
            "\($0) after \(name)"
        }
        return out
    }

    // MARK: leak test, every channel a token canary can enter through

    @Test func aCanaryStaysInItsFilesWhenItEntersAsTokenFileSetupOutputOrPaste() throws {
        let channels: [Channel] = [.tokenFileValue, .setupTokenOutput, .pastedToken]
        // One set of canaries, so the scan looks for exactly the values that were planted.
        let canaries = Canary.all()
        for (canary, channel, inputs) in PlantedInputs.everyCombination(canaries: canaries)
        where channels.contains(channel) {
            let cli = try setUp()
            defer { cli.cleanup() }
            // A token canary may sit in its token file and that label's launch files only. A
            // planted token file may hold any shape, and so may its launch files.
            var allowed: [String] = []
            if canary.name.hasPrefix("oauth-token") || channel == .tokenFileValue {
                allowed = Self.tokenHomes(dataFolder: cli.dataRoot.lastPathComponent, label: "lab")
            }
            var leaks: [String] = []
            func go(_ args: [String], stdin: String? = nil) throws -> Support.Output {
                try runAndCollect(
                    cli, args, stdin: stdin, into: &leaks, canaries: canaries, allowed: allowed)
            }
            func login() throws -> Support.Output {
                try cli.fake("setup-token.out", inputs.fakeClaudeStdout)
                return channel == .pastedToken
                    ? try go(["login", "lab", "--paste"], stdin: inputs.pastedInput)
                    : try go(["login", "lab"])
            }

            _ = try go(["add", "lab", "--email", "lab@example.com"])
            if channel == .tokenFileValue {
                let file = try tokenFile(cli, "lab")
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                // In the token file's own shape, so pick copies it into launch files and the
                // probe is given it.
                let value = inputs.files.values.joined()
                let body =
                    "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(value)\",\"\(LaunchFiles.accountVariable)\":\"lab\"}}"
                try body.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path)
            } else {
                let first = try login()
                if canary.name.hasPrefix("oauth-token") {
                    #expect(first.status == 0, "\(canary.name): \(text(first.stderr))")
                } else {
                    #expect(first.status == 1)
                }
            }

            _ = try go(["pick", "--json", "--exclude", "main"])
            _ = try go(["pick", "--json"])
            _ = try go(["status", "--json"])
            _ = try go(["status", "--cached", "--json"])
            _ = try go(["events", "--json"])
            _ = try go(["history", "--json"])
            _ = try go(["refresh", "--label", "lab", "--force"])
            _ = try go(["refresh", "--force"])
            _ = try go(["doctor"])
            _ = try go(["link", "--accept-source-change"])
            _ = try go(["config", "show"])
            _ = try go(["config", "validate"])
            _ = try go(["config", "set", "lab", "email", "other@example.com"])
            _ = try go(["config", "set", "lab", "ends", "2099-12-31"])
            _ = try go(["config", "set", "lab", "ending-soon", "true"])
            _ = try go(["config", "set", "refresh.backgroundMinutes", "30"])
            _ = try go(["config", "set-main", "lab"])
            _ = try go(["config", "clear-main", "lab"])
            _ = try go(["init", "--label", "again"])
            _ = try go(["--version"])
            _ = try go(["add", "other"])
            // The replace path: a second sign-in over the first.
            _ = try login()
            _ = try go(["pick", "--json", "--exclude", "main"])
            _ = try go(["remove", "other"])
            // Once the account is removed, the canary may be nowhere at all.
            allowed = []
            let removed = try go(["remove", "lab"])
            #expect(removed.status == 0, "\(canary.name) in \(channel): \(text(removed.stderr))")

            #expect(leaks.isEmpty, "\(canary.name) in \(channel): \(Set(leaks).sorted())")
        }
    }

    /// The picks log is under the data folder, so the scan above reads it; this proves it exists.
    @Test func thePicksLogExistsWhenTheLeakScanRuns() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try cli.fake("setup-token.out", oauth() + "\n")
        #expect(try cli.run(["login", "lab"]).status == 0)
        #expect(try cli.run(["pick", "--json", "--exclude", "main"]).status == 0)
        #expect(!cli.read("state/\(Layout.picksLogName)").isEmpty)
    }
}

extension CLIHome {
    /// stdout, stderr and the text of every file under the data folder except one.
    func everythingUnderData(_ out: Support.Output, excluding skipped: URL) -> String {
        var combined =
            String(decoding: out.stdout, as: UTF8.self)
            + String(decoding: out.stderr, as: UTF8.self)
        for url in dataEntries()
        where url.resolvingSymlinksInPath().path != skipped.resolvingSymlinksInPath().path {
            combined += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return combined
    }
}

extension TokenAccountsCLITests {
    @Test func configSetEndsSaysWhenItAlsoClearedTheEndingSoonFlag() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        let line = "Also cleared ending-soon: an account keeps one end marker."
        #expect(try cli.run(["config", "set", "lab", "ending-soon", "true"]).status == 0)
        let dated = try cli.run(["config", "set", "lab", "ends", "2099-12-31"])
        #expect(dated.status == 0)
        #expect(text(dated.stdout).contains(line))
        #expect(try cli.run(["config", "set", "lab", "ending-soon", "true"]).status == 0)
        let none = try cli.run(["config", "set", "lab", "ends", "none"])
        #expect(none.status == 0)
        #expect(text(none.stdout).contains(line))
        // With no soon flag to clear, it says nothing more.
        let plain = try cli.run(["config", "set", "lab", "ends", "2099-12-31"])
        #expect(plain.status == 0)
        #expect(!text(plain.stdout).contains("Also cleared"))
    }
}
