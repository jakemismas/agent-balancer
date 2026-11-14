import Foundation
import Testing

@testable import Core

/// `run`, `uninstall` and the extra `doctor` checks, through the calls the commands use.
@Suite struct PersonCommandsTests {
    func token(_ label: String = "pool-a") -> Account {
        Account(label: label, kind: Kind.token, role: Role.pool)
    }

    func login() -> Account {
        Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
            expectedPlanTier: "max_20x")
    }

    func setUp(_ accounts: [Account]) throws -> (TestHome, PickService) {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        var config = Config(accounts: accounts)
        config.fable.probe = false
        try ConfigStore(context: t.context).save(config)
        let hooks = HookRecord(context: t.context)
        try hooks.record(.empty)
        // A reader saves the verdict that `run` relies on.
        _ = try hooks.readSettings()
        return (t, PickService(context: t.context))
    }

    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func age(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    func write(_ body: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Every launch file under the launch folder, tombstones included.
    func launchFiles(_ t: TestHome) -> [URL] {
        let root = LaunchFiles.rootURL(context: t.context)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    }

    // MARK: run

    @Test func runBuildsTheLineAndOneLaunchFileAndALease() throws {
        let (t, service) = try setUp([login()])
        let launch = try service.prepareRun(label: "main", arguments: ["--model", "opus"])
        let files = launchFiles(t)
        #expect(files.count == 1)
        let path = launch.arguments.dropFirst().first ?? ""
        #expect(launch.arguments == ["--settings", path, "--model", "opus"])
        #expect(launch.line == "claude --settings '\(path)' --model opus")
        let real = { (url: URL) in url.resolvingSymlinksInPath().path }
        #expect(real(URL(fileURLWithPath: path)) == real(try #require(files.first)))
        #expect(TokenAccounts.openLeaseCount(context: t.context, leaseMinutes: 30) == 1)
    }

    @Test func runKeepsSettingsAheadOfASecondDoubleDash() throws {
        let (t, service) = try setUp([login()])
        defer { withExtendedLifetime(t) {} }
        let launch = try service.prepareRun(label: "main", arguments: ["foo", "--", "bar"])
        #expect(launch.arguments.first == "--settings")
        #expect(launch.arguments.suffix(3) == ["foo", "--", "bar"])
        #expect(launch.line.hasPrefix("claude --settings '"))
        #expect(launch.line.hasSuffix(" foo -- bar"))
    }

    @Test func runQuotesArgumentsForTheLine() throws {
        let (t, service) = try setUp([login()])
        defer { withExtendedLifetime(t) {} }
        let launch = try service.prepareRun(label: "main", arguments: ["it's here", "$HOME"])
        #expect(launch.line.hasPrefix("claude --settings '"))
        #expect(launch.line.hasSuffix(" 'it'\\''s here' '$HOME'"))
    }

    @Test func runOnATokenAccountNeverPutsTheTokenInTheLineOrTheArguments() throws {
        let (t, service) = try setUp([token()])
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let launch = try service.prepareRun(label: "pool-a", arguments: ["-c"])
        #expect(!launch.line.contains(secret))
        #expect(!launch.arguments.joined(separator: " ").contains(secret))
        // The token sits in the launch file the line names, and nowhere else the call wrote.
        #expect(text(try #require(launchFiles(t).first)).contains(secret))
        let leases = t.context.dataRoot.appendingPathComponent("state/leases.json")
        #expect(!text(leases).contains(secret))
    }

    @Test func runStartsWithNoReadingYet() throws {
        let (t, service) = try setUp([login()])
        let readings = t.context.dataRoot.appendingPathComponent("state/readings")
        #expect(!FileManager.default.fileExists(atPath: readings.path))
        _ = try service.prepareRun(label: "main", arguments: [])
    }

    @Test func runRefusesAMissingOrWidenedTokenFileWithTheTokenMissingText() throws {
        let (t, service) = try setUp([token()])
        #expect(throws: ToolError(Messages.tokenMissing("pool-a"), code: .tokenMissing)) {
            try service.prepareRun(label: "pool-a", arguments: [])
        }
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let file = try TokenPaths.fileURL(context: t.context, label: "pool-a")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: ToolError(Messages.tokenMissing("pool-a"), code: .tokenMissing)) {
            try service.prepareRun(label: "pool-a", arguments: [])
        }
        #expect(launchFiles(t).isEmpty)
    }

    @Test func runRefusesALoggedOutLoginWithTheLoginRejectedText() throws {
        let (t, service) = try setUp([login()])
        try t.fakeFixture(auth: "logged_out", exit: 1)
        do {
            _ = try service.prepareRun(label: "main", arguments: [])
            Issue.record("run started on a logged out account")
        } catch let error as ToolError {
            #expect(error.code == .loginRejected)
            #expect(error.message.hasPrefix("Login rejected."))
        }
        #expect(launchFiles(t).isEmpty)
    }

    @Test func runRefusesAnUnknownLabelAndAPersonSettingsFlag() throws {
        let (t, service) = try setUp([login()])
        #expect(throws: ToolError.self) { try service.prepareRun(label: "nope", arguments: []) }
        #expect(throws: ToolError.self) {
            try service.prepareRun(label: "main", arguments: ["--settings", "x.json"])
        }
        #expect(throws: ToolError.self) {
            try service.prepareRun(label: "main", arguments: ["--settings=x.json"])
        }
        #expect(launchFiles(t).isEmpty)
    }

    @Test func attachedLaunchGivesTheChildThePersonEnvironmentMinusTheProtectedGroup() throws {
        let t = try TestHome()
        try t.installFake()
        let ambient = [
            "HOME": t.home.path, "TERM": "xterm", "ANTHROPIC_API_KEY": "key-value",
            "CLAUDE_CONFIG_DIR": "/tmp/x",
            ProtectedEnv.tokenVariable: "tok", "KEEP_ME": "1",
        ]
        let runner = ClaudeRunner(context: t.context(ambient: ambient))
        let status = try runner.launchAttached(arguments: ["--version"])
        #expect(status == 0)
        let names = text(t.home.appendingPathComponent(".ab-fake/env-names.txt"))
        #expect(names.contains("KEEP_ME") && names.contains("TERM"))
        #expect(!names.contains("ANTHROPIC_API_KEY") && !names.contains("CLAUDE_CONFIG_DIR"))
        #expect(!names.contains(ProtectedEnv.tokenVariable))
    }

    // MARK: uninstall and the launch files a session names

    /// Two launch files of one token account, both old enough to be outside the lease window, with
    /// a session record that names the first.
    func twoFiles(_ t: TestHome, secret: String) throws -> (named: URL, unnamed: URL) {
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let namedURL = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: "l-0a0b0c0d", caller: .none)
        let unnamedURL = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: "l-1a1b1c1d", caller: .none)
        try age(namedURL, by: 3 * 3600)
        try age(unnamedURL, by: 3 * 3600)
        let record: [String: Any] = [
            "sessionId": "s1", "state": "running", "respawnFlags": ["--settings", namedURL.path],
        ]
        try write(
            String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self),
            to: t.home.appendingPathComponent(".claude/jobs/j1/state.json"))
        return (namedURL, unnamedURL)
    }

    @Test func afterUninstallNoLaunchFileHoldsATokenNamedOrNot() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        let (named, unnamed) = try twoFiles(t, secret: secret)

        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30)
        #expect(plan.launchFiles == 2 && plan.launchFilesNamed == 1 && plan.recordsReadable)
        #expect(plan.tokenFiles == 1)

        let done = try Uninstall.run(context: t.context, leaseMinutes: 30)
        #expect(done.launchFiles == 1 && done.launchFilesKept == 1 && done.tokenFiles == 1)
        #expect(!FileManager.default.fileExists(atPath: unnamed.path))
        #expect(FileManager.default.fileExists(atPath: named.path))
        for file in launchFiles(t) { #expect(!text(file).contains(secret)) }
        let kept = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: named)) as? [String: Any])
        let env = try #require(kept["env"] as? [String: String])
        #expect(env[ProtectedEnv.tokenVariable] == "invalid")
        // The token folder and every file of the tool outside the launch folder are gone.
        let tokenFolder = try TokenPaths.fileURL(context: t.context, label: "pool-a")
            .deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: tokenFolder.path))
        let state = t.context.dataRoot.appendingPathComponent("state")
        #expect(!FileManager.default.fileExists(atPath: state.path))
    }

    @Test func unreadableSessionRecordsKeepEveryLaunchFileAsATombstone() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        let (named, unnamed) = try twoFiles(t, secret: secret)
        let done = try Uninstall.run(
            context: t.context, leaseMinutes: 30, snapshot: .unreadable)
        #expect(done.launchFiles == 0 && done.launchFilesKept == 2)
        for file in [named, unnamed] {
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(!text(file).contains(secret))
        }
    }

    @Test func aYoungOrLeasedLaunchFileIsKeptAsATombstoneToo() throws {
        let t = try TestHome()
        let secret = Canaries.oauth()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: secret)
        let young = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: "l-0a0b0c0d", caller: .none)
        let leased = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: "l-1a1b1c1d", caller: .none)
        try age(leased, by: 3 * 3600)
        try LeaseStore(context: t.context).save([
            Lease(id: "l-1a1b1c1d", label: "pool-a", model: "default", at: Date())
        ])
        let done = try Uninstall.run(context: t.context, leaseMinutes: 30, snapshot: .empty)
        #expect(done.launchFiles == 0 && done.launchFilesKept == 2)
        for file in [young, leased] { #expect(!text(file).contains(secret)) }
    }

    @Test func uninstallRemovesAListedLinkOnlyWhileItIsTheSymlinkItMade() throws {
        let t = try TestHome()
        let account = t.context.dataRoot.appendingPathComponent("accounts/pool/.claude")
        for url in [
            t.context.dataRoot, t.context.dataRoot.appendingPathComponent("accounts"),
            t.context.dataRoot.appendingPathComponent("accounts/pool"), account,
        ] {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let target = t.home.appendingPathComponent("shared/source.json")
        try write("{}", to: target)
        let link = account.appendingPathComponent("source.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let regular = account.appendingPathComponent("NOTES.md")
        try write("notes", to: regular)
        let moved = account.appendingPathComponent("agents")
        try FileManager.default.createSymbolicLink(
            at: moved, withDestinationURL: t.home.appendingPathComponent("elsewhere"))
        // A listed path outside the account folders is never touched.
        let outside = t.home.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: target)

        let entries = [
            ["path": link.path, "target": target.path],
            ["path": regular.path, "target": "NOTES.md"],
            ["path": moved.path, "target": target.path],
            ["path": outside.path, "target": target.path],
        ]
        let manifest: [String: Any] = ["schemaVersion": 1, "links": entries]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: t.context.dataRoot.appendingPathComponent("links.json"))

        let plan = try Uninstall.plan(context: t.context, leaseMinutes: 30)
        #expect(plan.links == 4 && plan.linksIntact == 1 && plan.hasLinksFile)
        let done = try Uninstall.run(context: t.context, leaseMinutes: 30)
        #expect(done.linksRemoved == 1 && done.linksKept == 3)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(text(regular) == "notes")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: moved.path)) != nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: outside.path)) != nil)
        #expect(text(target) == "{}")
        #expect(FileManager.default.fileExists(atPath: account.path))
        let manifestFile = t.context.dataRoot.appendingPathComponent("links.json")
        #expect(!FileManager.default.fileExists(atPath: manifestFile.path))
    }

    @Test func uninstallLeavesWhatItDidNotMake() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let stranger = t.context.dataRoot.appendingPathComponent("accounts/keep/.claude/x.json")
        try write("{}", to: stranger)
        let note = t.context.dataRoot.appendingPathComponent("notes.txt")
        try write("mine", to: note)
        let done = try Uninstall.run(context: t.context, leaseMinutes: 30)
        #expect(done.tokenFiles == 1)
        #expect(FileManager.default.fileExists(atPath: stranger.path))
        #expect(FileManager.default.fileExists(atPath: note.path))
    }

    // MARK: doctor checks

    @Test func doctorCountsLaunchFilesAndTheOldestAge() throws {
        let t = try TestHome()
        _ = try TokenAccounts.install(context: t.context, label: "pool-a", token: Canaries.oauth())
        let old = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: "l-0a0b0c0d", caller: .none)
        _ = try LaunchFiles.create(
            context: t.context, account: token(), leaseId: "l-1a1b1c1d", caller: .none)
        try age(old, by: 3 * 86_400)
        let summary = DoctorChecks.launchFiles(context: t.context, snapshot: .empty)
        #expect(summary.count == 2)
        #expect(try #require(summary.oldestAge) > 2.9 * 86_400)
        #expect(DoctorChecks.describe(age: 3 * 86_400 + 10) == "3 days")
        #expect(DoctorChecks.describe(age: 3 * 3600) == "3 hours")
        #expect(DoctorChecks.describe(age: 5) == "under a minute")
        let empty = try TestHome()
        #expect(DoctorChecks.launchFiles(context: empty.context, snapshot: .empty).count == 0)
    }

    @Test func doctorWarnsWhenTheDataFolderSitsInASyncedFolder() throws {
        let plain = URL(fileURLWithPath: "/Users/example/work")
        #expect(DoctorChecks.syncedFolder(context: ToolContext(home: plain, ambient: [:])) == nil)
        for (path, name) in [
            ("/Users/example/Dropbox/home", "Dropbox"),
            ("/Users/example/Library/Mobile Documents/com~apple~CloudDocs/h", "iCloud Drive"),
            ("/Users/example/OneDrive - Example/h", "OneDrive"),
            ("/Users/example/Library/CloudStorage/GoogleDrive-a/h", "a cloud storage provider"),
        ] {
            let context = ToolContext(home: URL(fileURLWithPath: path), ambient: [:])
            #expect(DoctorChecks.syncedFolder(context: context) == name)
        }
    }
}
