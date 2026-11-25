import Core
import Foundation
import Testing

@testable import Core

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// The folder kind end to end against the fake `claude` in a temporary home.
@Suite struct FolderAccountsCLITests {
    static let hookSettings =
        #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"}]}]}}"#
    static let email = "acct@example.com"

    var context: (CLIHome) -> ToolContext { { ToolContext(home: $0.home, ambient: [:]) } }

    /// A home with a login account `main`, optionally a folder account `spare` whose folder is
    /// made, a shared source with settings and a CLAUDE.md, and a hook record.
    func setUp(folder: Bool = true, login: Bool = true) throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fake("default.exit", "0")
        try cli.fakeProbe("ok.jsonl")
        let ctx = context(cli)
        var accounts: [Account] = []
        if login {
            accounts.append(
                Account(
                    label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
                    expectedPlanTier: "max_20x"))
        }
        if folder {
            accounts.append(
                Account(
                    label: "spare", kind: Kind.folder, role: Role.pool, email: Self.email,
                    expectedPlanTier: "max_20x"))
        }
        var config = Config(accounts: accounts)
        config.fable.probe = false
        try ConfigStore(context: ctx).save(config)
        if folder {
            try NoFollowWriter(root: ctx.dataRoot).prepare(
                folders: FolderPaths.folders(label: "spare"))
            try signedIn(cli)
        }
        try cli.settings(Self.hookSettings)
        try "notes".write(
            to: cli.home.appendingPathComponent(".claude/CLAUDE.md"), atomically: true,
            encoding: .utf8)
        let hooks = HookRecord(context: ctx)
        try hooks.record(try hooks.readSettings())
        return cli
    }

    func folderPath(_ cli: CLIHome) throws -> String {
        try FolderPaths.configDir(context: context(cli), label: "spare").path
    }

    func authJSON(_ cli: CLIHome, loggedIn: Bool, email: String = Self.email) throws -> String {
        #"{"loggedIn":\#(loggedIn),"email":"\#(email)","planTier":"max_20x","configDirectory":"\#(try folderPath(cli))"}"#
    }

    func signedIn(_ cli: CLIHome, loggedIn: Bool = true) throws {
        try cli.fake("auth.json", try authJSON(cli, loggedIn: loggedIn))
        try cli.fake("auth.exit", "0")
    }

    func linked(_ cli: CLIHome) throws {
        let out = try cli.runOnTerminal(["link", "spare"], typing: "spare\n")
        #expect(out.status == 0, "\(text(out.stderr))")
    }

    func destination(_ cli: CLIHome, _ name: String) throws -> String? {
        try? FileManager.default.destinationOfSymbolicLink(
            atPath: URL(fileURLWithPath: folderPath(cli)).appendingPathComponent(name).path)
    }

    /// Modes of everything under the data folder except the links, which carry no mode of their own.
    func privateModes(_ cli: CLIHome) -> [String] {
        let linkNames = Set(SharedItems.all.map(\.name))
        return cli.expectPrivateModes().filter { !linkNames.contains($0) }
    }

    /// What a command printed plus the text of every file the tool made. A link is not read: what
    /// it points to is the user's own file.
    func leakText(_ cli: CLIHome, _ out: Support.Output) -> String {
        var all = text(out.stdout) + text(out.stderr)
        for url in cli.dataEntries() {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
            all += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return all
    }

    func json(_ out: Support.Output) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
    }

    func row(_ cli: CLIHome, _ label: String) throws -> [String: Any] {
        let out = try cli.run(["status", "--json", "--cached"])
        let accounts = try #require(try json(out)["accounts"] as? [[String: Any]])
        return try #require(accounts.first { $0["label"] as? String == label })
    }

    // MARK: add

    @Test func addFolderMakesAnEmptyPrivateFolderAndPrintsTheStepsInOrder() throws {
        let cli = try setUp(folder: false)
        defer { cli.cleanup() }
        let out = try cli.run(["add", "spare", "--kind", "folder", "--email", Self.email])
        #expect(out.status == 0, "\(text(out.stderr))")
        let shown = text(out.stdout)
        let steps = [
            "agent-balancer link spare", "agent-balancer login spare", Messages.trustStep,
            "MCP servers and plugins do not carry over", Messages.oneAccountPerFolder,
        ].map { shown.range(of: $0)?.lowerBound }
        #expect(!steps.contains { $0 == nil })
        let positions = steps.compactMap { $0 }
        #expect(positions == positions.sorted())
        let folder = URL(fileURLWithPath: try folderPath(cli))
        #expect(cli.mode(folder) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        let config = try ConfigStore(context: context(cli)).loadRequired()
        let account = try #require(config.account("spare"))
        #expect(account.kind == Kind.folder && account.email == Self.email)
        #expect(account.accountKey.count == 32)
        // No login ran: the fake saw no command at all.
        #expect(cli.fakeRecord("args.log").isEmpty)
        #expect(!cli.read("state/status.json").isEmpty)
        #expect(privateModes(cli).isEmpty)
        #expect(!shown.contains(Self.email))
    }

    @Test func addFolderRecordsTheEndDateAndTheEndingSoonFlag() throws {
        let cli = try setUp(folder: false)
        defer { cli.cleanup() }
        let day = "2099-12-31"
        let out = try cli.run(["add", "spare", "--kind", "folder", "--ends", day])
        #expect(out.status == 0, "\(text(out.stderr))")
        let account = try #require(
            try ConfigStore(context: context(cli)).loadRequired().account("spare"))
        #expect(account.endsAt == day && account.endingSoon == nil)
        let soon = try cli.run(["add", "soon", "--kind", "folder", "--ending-soon"])
        #expect(soon.status == 0, "\(text(soon.stderr))")
        let flagged = try #require(
            try ConfigStore(context: context(cli)).loadRequired().account("soon"))
        #expect(flagged.endsAt == nil && flagged.endingSoon == true)
        // An account keeps one end marker, so both together are refused and nothing is made.
        let both = try cli.run(["add", "both", "--kind", "folder", "--ends", day, "--ending-soon"])
        #expect(both.status == 1)
        #expect(text(both.stderr).contains("Use --ends or --ending-soon, not both"))
        #expect(try ConfigStore(context: context(cli)).loadRequired().account("both") == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: cli.dataRoot.appendingPathComponent("accounts/both").path))
        let past = try cli.run(["add", "old", "--kind", "folder", "--ends", "2001-01-01"])
        #expect(past.status == 1)
        let config = try ConfigStore(context: context(cli)).loadRequired()
        #expect(config.account("old") == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: cli.dataRoot.appendingPathComponent("accounts/old").path))
        let plain = try cli.run(["add", "plain", "--kind", "folder"])
        #expect(plain.status == 0)
        let none = try #require(
            try ConfigStore(context: context(cli)).loadRequired().account("plain"))
        #expect(none.endsAt == nil && none.endingSoon != true)
    }

    @Test func addFolderRefusesALabelThatIsUsedOrNotValid() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        for args in [["add", "spare", "--kind", "folder"], ["add", "Bad", "--kind", "folder"]] {
            #expect(try cli.run(args).status == 1)
        }
    }

    // MARK: link

    @Test func linkListsFirstAndAppliesOnlyWithTheLabelTypedBack() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let dry = try cli.run(["link", "spare", "--dry-run"])
        #expect(dry.status == 0)
        let listing = text(dry.stdout)
        #expect(listing.contains("settings.json: make the link"))
        #expect(listing.contains("agents: skipped, no source exists"))
        #expect(try destination(cli, "CLAUDE.md") == nil)
        // No answer, a wrong word and a flag that does not exist.
        #expect(try cli.run(["link", "spare"]).status == 1)
        #expect(try cli.runOnTerminal(["link", "spare"], typing: "yes\n").status == 1)
        #expect(try cli.runOnTerminal(["link", "spare", "--yes"], typing: "spare\n").status != 0)
        #expect(try destination(cli, "CLAUDE.md") == nil)

        let done = try cli.runOnTerminal(["link", "spare"], typing: "spare\n")
        #expect(done.status == 0)
        #expect(try destination(cli, "CLAUDE.md") != nil)
        #expect(try destination(cli, "settings.json") != nil)
        let manifest = cli.read("links.json")
        #expect(manifest.contains("linkedLabels") && manifest.contains("CLAUDE.md"))
        // Rebuilt at the end: the status shows the folder linked.
        #expect(try row(cli, "spare")["linked"] as? Bool == true)
        #expect(privateModes(cli).isEmpty)
    }

    @Test func everyConsentCommandRefusesInAChatShellAndProceedsInAnEditorTerminal() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let chat = ["CLAUDE_CODE_CHILD_SESSION": "1"]
        for args in [
            ["link", "spare"], ["link", "spare", "--repair"], ["unlink", "spare"],
            ["link", "--accept-source-change"], ["link", "--accept-source-change", "--all"],
        ] {
            let out = try cli.runOnTerminal(args, env: chat, typing: "spare\naccept\n")
            #expect(out.status == 1, "\(args)")
            #expect(text(out.stderr).contains(Messages.chatShellRefusal))
            #expect(!text(out.stderr).localizedCaseInsensitiveContains("unset"))
        }
        #expect(try destination(cli, "CLAUDE.md") == nil)
        let editor = try cli.run(["link", "spare", "--dry-run"], env: ["CLAUDECODE": "1"])
        #expect(editor.status == 0)
    }

    @Test func linkRefusesWhenADestinationIsInTheWayAndChangesNothing() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try "mine".write(
            to: URL(fileURLWithPath: try folderPath(cli)).appendingPathComponent("CLAUDE.md"),
            atomically: true, encoding: .utf8)
        let out = try cli.runOnTerminal(["link", "spare"], typing: "spare\n")
        #expect(out.status == 1)
        #expect(text(out.stdout).contains("Refused"))
        #expect(try destination(cli, "settings.json") == nil)
        #expect(!cli.read("links.json").contains("spare/.claude"))
    }

    @Test func linkOnTheDefaultFolderOrATokenAccountIsRefused() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        #expect(try cli.runOnTerminal(["link", "main"], typing: "main\n").status == 1)
        #expect(try cli.runOnTerminal(["link", "nobody"], typing: "nobody\n").status == 1)
        #expect(try cli.run(["link"]).status == 1)
        #expect(try cli.run(["link", "--all"]).status == 1)
    }

    @Test func linkRefusesUntilAChangedHookSetIsAccepted() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.settings(#"{"hooks":{}}"#)
        let stale = try cli.runOnTerminal(["link", "spare"], typing: "spare\n")
        #expect(stale.status == 1)
        #expect(text(stale.stderr).contains("agent-balancer doctor"))
        _ = try cli.run(["doctor"])
        let out = try cli.runOnTerminal(["link", "spare"], typing: "spare\n")
        #expect(out.status == 1)
        #expect(text(out.stderr).contains("--accept-source-change --all"))
        #expect(try destination(cli, "CLAUDE.md") == nil)
    }

    @Test func unlinkRemovesOnlyTheRecordedLinks() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        #expect(try cli.runOnTerminal(["unlink", "spare"], typing: "no\n").status == 1)
        #expect(try destination(cli, "CLAUDE.md") != nil)
        let out = try cli.runOnTerminal(["unlink", "spare"], typing: "spare\n")
        #expect(out.status == 0)
        #expect(try destination(cli, "CLAUDE.md") == nil)
        #expect(try destination(cli, "settings.json") == nil)
        #expect(FileManager.default.fileExists(atPath: try folderPath(cli)))
        #expect(try row(cli, "spare")["linked"] as? Bool == false)
    }

    // MARK: accept-source-change

    @Test func aRemovedHookFailsEveryAccountAndAllClearsThemWithOneBanner() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        #expect(try cli.run(["pick", "--json"]).status == 0)
        try cli.settings(#"{"hooks":{}}"#)
        let pick = try cli.run(["pick", "--json"])
        #expect(pick.status == 2)

        let status = try json(try cli.run(["status", "--json"]))
        let banner = try #require(status["banner"] as? [String: Any])
        #expect(banner["text"] as? String == Messages.settingsChangedAll)
        let accounts = try #require(status["accounts"] as? [[String: Any]])
        for account in accounts {
            #expect((account["error"] as? [String: Any])?["code"] as? String == "settings_changed")
        }
        // One error event per affected account.
        let events = cli.read("state/events.jsonl").split(separator: "\n").filter {
            $0.contains("\"settings_changed\"") && $0.contains("\"error\"")
        }
        #expect(events.count == 2)

        let accept = try cli.runOnTerminal(
            ["link", "--accept-source-change", "--all"], typing: "accept\n")
        #expect(accept.status == 0)
        let shown = text(accept.stdout)
        #expect(shown.contains("Hook entries removed: 1") && shown.contains("spare"))
        #expect(!shown.contains("echo one"))
        #expect(try cli.run(["pick", "--json"]).status == 0)
        let after = try json(try cli.run(["status", "--json"]))
        #expect(after["banner"] is NSNull || after["banner"] == nil)
    }

    @Test func theBannerOfALoginOnlySetupNamesNoAll() throws {
        let cli = try setUp(folder: false)
        defer { cli.cleanup() }
        try cli.fakeFixture("logged_in")
        try cli.settings(#"{"hooks":{}}"#)
        let hooks = HookRecord(context: context(cli))
        try hooks.record(
            SettingsFacts(
                hooks: [
                    HookEntry(
                        event: "Stop", matcher: "", commandHash: String(repeating: "a", count: 64),
                        fingerprint: String(repeating: "b", count: 64))
                ], disableAllHooks: false, apiKeyHelperPresent: false, keyEnvNames: []))
        // `pick` reads the settings, so the status shows what it found.
        _ = try cli.run(["pick", "--json"])
        let status = try json(try cli.run(["status", "--json"]))
        let banner = try #require(status["banner"] as? [String: Any])
        #expect(banner["text"] as? String == Messages.settingsChanged)
    }

    @Test func acceptSourceChangeWithALabelNeedsALinkedFolder() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        #expect(
            try cli.runOnTerminal(["link", "--accept-source-change", "spare"], typing: "accept\n")
                .status == 1)
        try linked(cli)
        #expect(
            try cli.runOnTerminal(["link", "--accept-source-change", "spare"], typing: "accept\n")
                .status == 0)
    }

    // MARK: verify

    @Test func verifyPassesAndFailsOnEachDrift() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let never = try cli.run(["verify", "spare", "--no-reading"])
        #expect(never.status == 1)
        #expect(text(never.stdout).contains("not_linked"))
        try linked(cli)
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0)
        // Without --no-reading a reading is needed.
        #expect(try cli.run(["verify", "spare"]).status == 1)
        #expect(try cli.run(["refresh", "--label", "spare"]).status == 0)
        #expect(try cli.run(["verify", "spare"]).status == 0)
        // A wrong login.
        try cli.fake("auth.json", try authJSON(cli, loggedIn: true, email: "other@example.com"))
        #expect(
            text(try cli.run(["verify", "spare", "--no-reading"]).stdout).contains("wrong_account"))
        try signedIn(cli)
        // A hook removed.
        try cli.settings(#"{"hooks":{}}"#)
        let hook = try cli.run(["verify", "spare", "--no-reading"])
        #expect(hook.status == 1 && text(hook.stdout).contains("settings_changed"))
        try cli.settings(Self.hookSettings)
        // A broken link.
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: try folderPath(cli)).appendingPathComponent("CLAUDE.md"))
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 1)
        // A login or token label is not verified here.
        #expect(try cli.run(["verify", "main"]).status == 1)
    }

    @Test func verifyFailsOnAStaleReadingAndNamesTheRefreshCommand() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        #expect(try cli.run(["refresh", "--label", "spare"]).status == 0)
        #expect(try cli.run(["verify", "spare"]).status == 0)
        let store = ReadingStore(context: context(cli))
        var reading = try #require(try store.load(label: "spare"))
        reading.readAt = Date().addingTimeInterval(-86_400)
        try store.save(reading, label: "spare")
        let stale = try cli.run(["verify", "spare"])
        #expect(stale.status == 1)
        #expect(text(stale.stdout).contains("older than"))
        #expect(text(stale.stdout).contains("agent-balancer refresh --label spare"))
        #expect(!text(stale.stdout).contains("passed"))
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0)
    }

    @Test func aSourceThatAppearsAfterLinkFailsVerifyAndRepairWithTheTypedLabelClearsIt() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0)
        try FileManager.default.createDirectory(
            at: cli.home.appendingPathComponent(".claude/skills"),
            withIntermediateDirectories: true)
        let failed = try cli.run(["verify", "spare", "--no-reading"])
        #expect(failed.status == 1)
        #expect(text(failed.stdout).contains("agent-balancer link --repair spare"))
        #expect(try destination(cli, "skills") == nil)
        // No typed label, no change.
        #expect(try cli.runOnTerminal(["link", "--repair", "spare"], typing: "no\n").status == 1)
        #expect(try destination(cli, "skills") == nil)
        let repaired = try cli.runOnTerminal(["link", "--repair", "spare"], typing: "spare\n")
        #expect(repaired.status == 0, "\(text(repaired.stderr))")
        #expect(try destination(cli, "skills") != nil)
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0)
    }

    @Test func aSettingsLinkPointedAtAnotherFileAfterLinkIsRefusedUntilRepair() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let fm = FileManager.default
        // The default folder's settings file is a link into a dotfiles folder, as `link` saw it.
        let dotfiles = cli.home.appendingPathComponent("dotfiles")
        try fm.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let first = dotfiles.appendingPathComponent("settings-a.json")
        let second = dotfiles.appendingPathComponent("settings-b.json")
        for file in [first, second] {
            try Self.hookSettings.write(to: file, atomically: true, encoding: .utf8)
        }
        let shared = cli.home.appendingPathComponent(".claude/settings.json")
        try fm.removeItem(at: shared)
        try fm.createSymbolicLink(at: shared, withDestinationURL: first)
        // A reader saves the settings verdict that `link` takes, as the refusal says to.
        _ = try cli.run(["doctor"])
        try linked(cli)
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0)
        let before = try #require(try destination(cli, "settings.json"))

        // The default folder's link now points at another file with the same hooks.
        try fm.removeItem(at: shared)
        try fm.createSymbolicLink(at: shared, withDestinationURL: second)
        let repair = "agent-balancer link --repair spare"
        let verify = try cli.run(["verify", "spare", "--no-reading"])
        #expect(verify.status == 1)
        #expect(text(verify.stdout).contains(repair))
        #expect(text(verify.stdout).contains("points to an older target"))
        let pick = try cli.run(["pick", "--json", "--dry-run"])
        let candidates = try #require(try json(pick)["candidates"] as? [[String: Any]])
        let spare = try #require(candidates.first { $0["label"] as? String == "spare" })
        #expect(spare["eligible"] as? Bool == false)
        #expect(spare["reason"] as? String == Messages.olderTarget("spare", "settings.json"))
        #expect((spare["reason"] as? String)?.contains(repair) == true)
        let run = try cli.run(["run", "spare"])
        #expect(run.status == 1)
        #expect(text(run.stderr).contains(repair))
        let error = try row(cli, "spare")["error"] as? [String: Any]
        #expect(error?["code"] as? String == "settings_changed")
        #expect((error?["text"] as? String)?.contains(repair) == true)

        // Repair links the new target, and the account is offered again.
        let repaired = try cli.runOnTerminal(["link", "--repair", "spare"], typing: "spare\n")
        #expect(repaired.status == 0, "\(text(repaired.stderr))")
        let after = try #require(try destination(cli, "settings.json"))
        #expect(after != before && after.hasSuffix("/dotfiles/settings-b.json"))
        #expect(try cli.run(["verify", "spare", "--no-reading"]).status == 0)
        let again = try cli.run(["pick", "--json", "--dry-run"])
        let offered = try #require(try json(again)["candidates"] as? [[String: Any]])
        #expect(offered.first { $0["label"] as? String == "spare" }?["eligible"] as? Bool == true)
    }

    @Test func verifyFailsWhenTheSignInFolderIsNotReported() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try cli.fake(
            "auth.json",
            #"{"loggedIn":true,"email":"\#(Self.email)","planTier":"max_20x"}"#)
        let out = try cli.run(["verify", "spare", "--no-reading"])
        #expect(out.status == 1)
        #expect(text(out.stdout).contains("could not be confirmed"))
        #expect(!text(out.stdout).contains("passed"))
    }

    @Test func unlinkPrintsNoControlCharacterFromTheRecord() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let folder = try folderPath(cli)
        let esc = "x\u{1b}[31mred"
        let record: [String: Any] = [
            "schemaVersion": 1,
            "links": [["path": folder + "/" + esc, "target": "/tmp/none"]],
            "linkedLabels": ["spare"],
        ]
        let data = try JSONSerialization.data(withJSONObject: record)
        let url = cli.dataRoot.appendingPathComponent("links.json")
        try data.write(to: url)
        chmod(url.path, 0o600)
        let out = try cli.runOnTerminal(["unlink", "spare"], typing: "spare\n")
        #expect(!text(out.stdout).contains("\u{1b}"))
        #expect(!text(out.stderr).contains("\u{1b}"))
    }

    @Test func addingAHookOrAStatusLinePassesAndACanaryInEnvNeverReachesAnyOutput() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let canary = Canary.randomTail(24)
        try cli.settings(
            #"{"env":{"SOME_VALUE":"\#(canary)"},"statusLine":{"type":"command","command":"x"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"}]},{"hooks":[{"type":"command","command":"echo \#(canary)"}]}]}}"#
        )
        let out = try cli.run(["verify", "spare", "--no-reading"])
        #expect(out.status == 0)
        let doctor = try cli.run(["doctor"])
        let link = try cli.runOnTerminal(["link", "--accept-source-change"], typing: "accept\n")
        for result in [out, doctor, link] {
            #expect(!leakText(cli, result).contains(canary))
        }
    }

    // MARK: login

    @Test func loginStartsClaudeInTheFolderAndReportsTheExpectedAccount() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try signedIn(cli, loggedIn: false)
        try cli.fake("auth-after-sign-in.json", try authJSON(cli, loggedIn: true))
        // Expected plan is learned at the first sign-in.
        var config = try ConfigStore(context: context(cli)).loadRequired()
        config.accounts[1].expectedPlanTier = nil
        try ConfigStore(context: context(cli)).save(config)

        let out = try cli.run(["login", "spare"])
        #expect(out.status == 0, "\(text(out.stderr)) \(text(out.stdout))")
        let shown = text(out.stdout)
        #expect(shown.contains(Messages.oneAccountPerFolder))
        #expect(shown.contains("The folder holds the expected account."))
        #expect(!shown.contains(Self.email))
        let folder = try folderPath(cli)
        let launches = cli.fakeRecord("config-dirs.log").split(separator: "\n").map(String.init)
        #expect(launches.allSatisfy { $0 == folder })
        let tier = try ConfigStore(context: context(cli)).loadRequired().account("spare")?
            .expectedPlanTier
        #expect(tier == "max_20x")
        #expect(cli.fakeRecord("args.log").contains("auth status"))
    }

    @Test func aLinkedParentOfTheAccountFolderIsRefused() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let ctx = context(cli)
        let parent = ctx.dataRoot.appendingPathComponent("accounts/spare", isDirectory: true)
        let moved = ctx.dataRoot.appendingPathComponent("accounts/elsewhere", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        #expect(FolderPaths.state(context: ctx, label: "spare") == .refused)
    }

    @Test func refreshRecordsTheExpectedPlanOfASignedInFolder() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try signedIn(cli, loggedIn: true)
        var config = try ConfigStore(context: context(cli)).loadRequired()
        config.accounts[1].expectedPlanTier = nil
        try ConfigStore(context: context(cli)).save(config)

        _ = try cli.run(["refresh", "--label", "spare", "--force"])
        let tier = try ConfigStore(context: context(cli)).loadRequired().account("spare")?
            .expectedPlanTier
        #expect(tier == "max_20x")
    }

    @Test func loginBrowserRunsAuthLoginWithTheExpectedEmail() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try signedIn(cli, loggedIn: false)
        try cli.fake("auth-after-sign-in.json", try authJSON(cli, loggedIn: true))
        let out = try cli.run(["login", "spare", "--browser"])
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(cli.fakeRecord("args.log").contains("auth login"))
        #expect(cli.fakeRecord("args.log").contains("auth login --email \(Self.email)"))
        #expect(!text(out.stdout).contains(Self.email))
    }

    @Test func loginRefusesTheWrongAccountWithTheFixAndNeverRelabels() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try signedIn(cli, loggedIn: false)
        try cli.fake(
            "auth-after-sign-in.json", try authJSON(cli, loggedIn: true, email: "other@example.com")
        )
        let out = try cli.run(["login", "spare"])
        #expect(out.status == 1)
        let shown = text(out.stdout)
        #expect(shown.contains("wrong_account"))
        #expect(shown.contains("Sign the expected account back in"))
        #expect(!shown.contains("other@example.com"))
        let account = try ConfigStore(context: context(cli)).loadRequired().account("spare")
        #expect(account?.email == Self.email)
    }

    @Test func loginFailsWhenTheSignInIsNotShownToBeInTheFolder() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try signedIn(cli, loggedIn: false)
        try cli.fake(
            "auth-after-sign-in.json",
            #"{"loggedIn":true,"email":"\#(Self.email)","planTier":"max_20x"}"#)
        let out = try cli.run(["login", "spare"])
        #expect(out.status == 1)
        #expect(text(out.stdout).contains("could not be confirmed"))
        #expect(!text(out.stdout).contains("Signed in."))
        let account = try ConfigStore(context: context(cli)).loadRequired().account("spare")
        #expect(account?.expectedPlanTier == "max_20x")
    }

    @Test func loginRefusesAnUnlinkedFolderASignedInFolderATokenAndAChatShell() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try signedIn(cli, loggedIn: false)
        let unlinked = try cli.run(["login", "spare"])
        #expect(unlinked.status == 1 && text(unlinked.stderr).contains("not linked"))
        try linked(cli)
        let chat = try cli.run(["login", "spare"], env: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        #expect(chat.status == 1)
        #expect(!cli.fakeRecord("args.log").contains("--settings"))
        try signedIn(cli, loggedIn: true)
        let signed = try cli.run(["login", "spare"])
        #expect(signed.status == 1 && text(signed.stderr).contains("already signed in"))
        // The fake never started for an interactive launch in any refused case.
        let config = try ConfigStore(context: context(cli)).loadRequired()
        var more = config
        more.accounts.append(Account(label: "tok", kind: Kind.token, role: Role.pool))
        try ConfigStore(context: context(cli)).save(more)
        let token = try cli.run(["login", "tok", "--browser"])
        #expect(token.status == 1)
        #expect(try cli.run(["login", "spare", "--paste"]).status == 1)
        let args = cli.fakeRecord("args.log").split(separator: "\n").map(String.init)
        #expect(args.allSatisfy { $0.hasPrefix("auth status") })
    }

    @Test func loginRefusesASignedInFolderWhoseLastProbeFailedWithoutARejection() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        // The probe fails without finding the sign-in rejected, and `auth status` still lists it.
        try cli.fakeProbe("no_event.jsonl")
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 1)
        #expect(
            (try statusRow(cli)["error"] as? [String: Any])?["code"] as? String == "check_failed")
        let out = try cli.run(["login", "spare", "--browser"])
        #expect(out.status == 1 && text(out.stderr).contains("already signed in"))
        #expect(!cli.fakeRecord("args.log").contains("auth login"))
    }

    // MARK: remove

    @Test func removeDeletesTheEntryItsLaunchFilesAndLeasesButNeverTheFolder() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let pick = try cli.run(["pick", "--json", "--exclude", "main"])
        #expect(pick.status == 0)
        #expect(
            cli.dataEntries().contains { $0.lastPathComponent.hasPrefix("l-") })
        let chat = try cli.run(["remove", "spare"], env: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        #expect(chat.status == 1)
        let out = try cli.run(["remove", "spare"])
        #expect(out.status == 0)
        let shown = text(out.stdout)
        #expect(
            shown.contains("stays") && shown.contains("~/.agent-balancer/accounts/spare/.claude"))
        #expect(FileManager.default.fileExists(atPath: try folderPath(cli)))
        #expect(try destination(cli, "CLAUDE.md") != nil)
        #expect(!cli.dataEntries().contains { $0.lastPathComponent.hasPrefix("l-") })
        #expect(!cli.read("state/leases.json").contains("spare"))
        #expect(try ConfigStore(context: context(cli)).loadRequired().account("spare") == nil)
        // Added again, the account is not linked until `link` runs again.
        #expect(try cli.run(["add", "spare", "--kind", "folder"]).status == 0)
        #expect(try row(cli, "spare")["linked"] as? Bool == false)
    }

    // MARK: run

    @Test func runStartsClaudeInTheFolderAndAChatShellGetsTheLine() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let folder = try folderPath(cli)
        let before = try cli.run(["run", "spare"])
        #expect(before.status == 1, "an unlinked folder is refused even by name")
        #expect(!text(before.stderr).isEmpty)
        try linked(cli)
        try cli.fake("default.exit", "0")
        let out = try cli.run(["run", "spare", "--", "--model", "opus"])
        #expect(out.status == 0, "\(text(out.stderr))")
        let dirs = cli.fakeRecord("config-dirs.log").split(separator: "\n").map(String.init)
        #expect(dirs.last == folder)
        let args = cli.fakeRecord("args.log").split(separator: "\n").map(String.init)
        let started = try #require(args.last)
        #expect(started.hasPrefix("--settings ") && started.hasSuffix(" --model opus"))

        let printed = try cli.run(["run", "--print-command", "spare", "--", "--model", "opus"])
        #expect(printed.status == 0)
        #expect(text(printed.stdout).hasPrefix("CLAUDE_CONFIG_DIR='\(folder)' claude --settings '"))

        let count = cli.fakeRecord("args.log").count
        let chat = try cli.run(
            ["run", "spare", "--", "--model", "opus"], env: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        #expect(chat.status == 1)
        #expect(text(chat.stdout).contains("agent-balancer run spare -- --model opus"))
        #expect(cli.fakeRecord("args.log").count == count)
    }

    // MARK: doctor, status, uninstall

    @Test func doctorRepeatsTheTrustStepAndNeverReadsTheClaudeJson() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        let canary = Canary.randomTail(24)
        try #"{"projects":{"\#(canary)":{}}}"#.write(
            to: cli.home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let out = try cli.run(["doctor"])
        let shown = text(out.stdout)
        #expect(shown.contains(Messages.trustStep) && shown.contains(Messages.notCarriedOver))
        #expect(shown.contains("Settings not shared."))
        #expect(shown.contains("session folder: default"))
        #expect(!leakText(cli, out).contains(canary))
        try linked(cli)
        #expect(text(try cli.run(["doctor"]).stdout).contains("links: intact"))
        let inFolder = try cli.run(["doctor"], env: ["CLAUDE_CONFIG_DIR": try folderPath(cli)])
        #expect(text(inFolder.stdout).contains("session folder: folder spare"))
    }

    @Test func statusFillsLinkedAndConfigDirForFolderAccountsOnly() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.fakeFixture("logged_in")
        let spare = try row(cli, "spare")
        #expect(spare["linked"] as? Bool == false)
        #expect(spare["configDir"] as? String == "~/.agent-balancer/accounts/spare/.claude")
        #expect((spare["error"] as? [String: Any])?["code"] as? String == "not_linked")
        let main = try row(cli, "main")
        #expect(main["linked"] is NSNull && main["configDir"] is NSNull)
        #expect(main["fullLogin"] as? Bool == true && spare["fullLogin"] as? Bool == true)
    }

    @Test func uninstallRemovesTheLinksAndNeverTheAccountsFolder() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let out = try cli.run(["uninstall"], stdin: "uninstall\n")
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(try destination(cli, "CLAUDE.md") == nil)
        #expect(FileManager.default.fileExists(atPath: try folderPath(cli)))
    }

    @Test func aFolderPickLeaksNothingPersonal() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        let out = try cli.run(["pick", "--json", "--exclude", "main"])
        #expect(out.status == 0)
        let answer = try json(out)
        let dir = try folderPath(cli)
        #expect((answer["env"] as? [String: String]) == ["CLAUDE_CONFIG_DIR": dir])
        #expect(answer["launchPrefix"] as? String == "CLAUDE_CONFIG_DIR='\(dir)' ")
        let allowed = [cli.read("config.json"), cli.read("state/status.json")]
        var rest = leakText(cli, out)
        for known in allowed { rest = rest.replacingOccurrences(of: known, with: "") }
        #expect(!rest.contains(Self.email))
        #expect(privateModes(cli).isEmpty)
    }
}
