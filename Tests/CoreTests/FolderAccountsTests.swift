import Foundation
import Testing

@testable import Core

/// The folder kind in a temporary home against the fake `claude`: links, the verifier, the
/// recipe, the ambient rule and in-use.
@Suite struct FolderAccountsTests {
    static let hookSettings =
        #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"}]}]}}"#

    /// A home with the fake claude, a saved config with the given accounts, the account folders
    /// made, a hook record of the default folder and a shared source with settings and a CLAUDE.md.
    func setUp(
        folders: [String] = ["spare"], extra: [Account] = [], settings: String? = hookSettings,
        ambient: [String: String] = [:], tune: (inout Config) -> Void = { _ in }
    ) throws -> (TestHome, ToolContext) {
        let t = try TestHome()
        try t.installFake()
        try t.fakeProbe("ok.jsonl")
        let context = t.context(ambient: ambient)
        var config = Config(
            accounts: extra
                + folders.map {
                    Account(
                        label: $0, kind: Kind.folder, role: Role.pool, email: "acct@example.com",
                        expectedPlanTier: "max_20x")
                })
        config.fable.probe = false
        tune(&config)
        try ConfigStore(context: context).save(config)
        let writer = NoFollowWriter(root: context.dataRoot)
        for label in folders {
            try writer.prepare(folders: FolderPaths.folders(label: label))
        }
        try fakeAuth(t, context: context, label: folders.first ?? "spare")
        // The default folder answers as the example main account, so a login account is its own.
        if !extra.isEmpty {
            try t.fake(
                "auth-default.json",
                try String(
                    contentsOf: t.fixtures.appendingPathComponent("auth/logged_in.json"),
                    encoding: .utf8))
        }
        let source = t.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "notes".write(
            to: source.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        if let settings {
            try settings.write(
                to: source.appendingPathComponent("settings.json"), atomically: true,
                encoding: .utf8)
        }
        let hooks = HookRecord(context: context)
        try hooks.record(try hooks.readSettings())
        return (t, context)
    }

    func fakeAuth(
        _ t: TestHome, context: ToolContext, label: String, loggedIn: Bool = true,
        email: String = "acct@example.com", folder: String? = nil
    ) throws {
        let dir = try folder ?? FolderPaths.configDir(context: context, label: label).path
        let json =
            #"{"loggedIn":\#(loggedIn),"email":"\#(email)","planTier":"max_20x","configDirectory":"\#(dir)"}"#
        try t.fake("auth.json", json)
        try t.fake("auth.exit", "0")
    }

    func link(_ context: ToolContext, _ label: String = "spare", repair: Bool = false) throws
        -> Linker.Applied
    {
        let config = try ConfigStore(context: context).loadRequired()
        let plan = try Linker.plan(context: context, config: config, label: label, repair: repair)
        let applied = try Linker.apply(context: context, plan: plan)
        let hooks = HookRecord(context: context)
        try hooks.record(try hooks.readSettings())
        return applied
    }

    func real(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func accountFolder(_ context: ToolContext, _ label: String = "spare") throws -> URL {
        try FolderPaths.configDir(context: context, label: label)
    }

    func destination(_ context: ToolContext, _ name: String, label: String = "spare") throws
        -> String?
    {
        try? FileManager.default.destinationOfSymbolicLink(
            atPath: accountFolder(context, label).appendingPathComponent(name).path)
    }

    func pick(_ context: ToolContext, _ request: PickRequest = PickRequest()) throws -> PickResult {
        try PickService(context: context).pick(request)
    }

    // MARK: Paths

    @Test func theFolderPathPatternRefusesRelativeDotAndOddNames() {
        #expect(FolderPaths.isValidPath("/a/b/.agent-balancer/accounts/x/.claude"))
        for bad in ["a/b", "/a/../b", "/a/./b", "/a b/c", "/a/b'c", "", "/", "/a//b"] {
            #expect(!FolderPaths.isValidPath(bad), "\(bad)")
        }
    }

    // MARK: Link plans

    @Test func linkMakesOneHopLinksForTheSourcesThatExistAndSkipsTheRest() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let skills = t.home.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let config = try ConfigStore(context: context).loadRequired()
        let plan = try Linker.plan(context: context, config: config, label: "spare", repair: false)
        let actions = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.name, $0.action) })
        #expect(actions["settings.json"] == .create)
        #expect(actions["CLAUDE.md"] == .create)
        #expect(actions["skills"] == .create)
        #expect(actions["agents"] == .skipMissing)
        #expect(actions["commands"] == .skipMissing)
        // The plan changes nothing.
        #expect(try destination(context, "settings.json") == nil)
        #expect(!HookRecord(context: context).isLinked("spare"))

        let applied = try link(context)
        #expect(applied.created == 3 && applied.skipped == 2)
        let target = real(t.home.appendingPathComponent(".claude/CLAUDE.md"))
        #expect(try destination(context, "CLAUDE.md") == target)
        #expect(try destination(context, "agents") == nil)
        let hooks = HookRecord(context: context)
        #expect(hooks.isLinked("spare"))
        #expect(hooks.entries(for: "spare").count == 3)
        #expect(hooks.sharesSettings("spare"))
        // Never linked: the per-account state and the session records.
        for name in ["projects", "plugins", "sessions", ".claude.json"] {
            #expect(try destination(context, name) == nil)
        }
    }

    @Test func aSecondRunLinksSourcesThatExistNowAndLeavesTheRest() throws {
        let (t, context) = try setUp(settings: nil)
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        #expect(try destination(context, "settings.json") == nil)
        let before = try destination(context, "CLAUDE.md")
        try Self.hookSettings.write(
            to: t.home.appendingPathComponent(".claude/settings.json"), atomically: true,
            encoding: .utf8)
        // A reader sees the new file first, as `link` asks before it applies.
        _ = try HookRecord(context: context).readSettings()
        let applied = try link(context)
        #expect(applied.created == 1 && applied.present == 1)
        #expect(try destination(context, "settings.json") != nil)
        #expect(try destination(context, "CLAUDE.md") == before)
        #expect(HookRecord(context: context).sharesSettings("spare"))
    }

    @Test func nothingToShareRecordsAnEmptyManifestAndCountsAsLinked() throws {
        let (t, context) = try setUp(settings: nil)
        defer { withExtendedLifetime(t) {} }
        try FileManager.default.removeItem(at: t.home.appendingPathComponent(".claude/CLAUDE.md"))
        let applied = try link(context)
        #expect(applied.created == 0)
        let hooks = HookRecord(context: context)
        #expect(hooks.isLinked("spare"))
        #expect(hooks.entries(for: "spare").isEmpty)
        #expect(Verifier.linkFacts(context: context, label: "spare").verdict == .ok)
    }

    @Test func aSymlinkedSourceIsLinkedToItsResolvedTarget() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let dotfiles = t.home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try "real".write(
            to: dotfiles.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let source = t.home.appendingPathComponent(".claude/CLAUDE.md")
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(
            at: source, withDestinationURL: dotfiles.appendingPathComponent("CLAUDE.md"))
        let config = try ConfigStore(context: context).loadRequired()
        let plan = try Linker.plan(context: context, config: config, label: "spare", repair: false)
        let item = try #require(plan.items.first { $0.name == "CLAUDE.md" })
        let target = real(dotfiles.appendingPathComponent("CLAUDE.md"))
        #expect(item.sourceIsLink && item.target == target)
        _ = try link(context)
        #expect(try destination(context, "CLAUDE.md") == target)
    }

    @Test func linkRefusesAndChangesNothingWhenADestinationIsInTheWay() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let folder = try accountFolder(context)
        try "mine".write(
            to: folder.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let config = try ConfigStore(context: context).loadRequired()
        let plan = try Linker.plan(context: context, config: config, label: "spare", repair: false)
        #expect(plan.conflicts.count == 1)
        #expect(throws: ToolError.self) { _ = try Linker.apply(context: context, plan: plan) }
        #expect(try destination(context, "settings.json") == nil)
        #expect(!HookRecord(context: context).isLinked("spare"))
        #expect(
            try String(
                contentsOf: folder.appendingPathComponent("CLAUDE.md"), encoding: .utf8) == "mine")
    }

    @Test func linkRefusesASourceOfTheWrongTypeAndAFolderThatIsALink() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let source = t.home.appendingPathComponent(".claude/skills")
        try "not a folder".write(to: source, atomically: true, encoding: .utf8)
        let config = try ConfigStore(context: context).loadRequired()
        let plan = try Linker.plan(context: context, config: config, label: "spare", repair: false)
        #expect(plan.conflicts.contains { $0.hasPrefix("skills:") })

        let folder = try accountFolder(context)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(
            at: folder, withDestinationURL: t.home.appendingPathComponent("elsewhere"))
        #expect(throws: ToolError.self) {
            _ = try Linker.plan(context: context, config: config, label: "spare", repair: false)
        }
    }

    @Test func linkRefusesASharedSourceThatIsNotTheDefaultFolder() throws {
        let (t, context) = try setUp { $0.sharedSource = "/tmp/dotfiles" }
        defer { withExtendedLifetime(t) {} }
        let config = try ConfigStore(context: context).loadRequired()
        #expect(throws: ToolError.self) {
            _ = try Linker.plan(context: context, config: config, label: "spare", repair: false)
        }
    }

    @Test func linkRefusesALabelThatIsNotAFolderAccount() throws {
        let (t, context) = try setUp(extra: [
            Account(label: "tok", kind: Kind.token, role: Role.pool)
        ])
        defer { withExtendedLifetime(t) {} }
        let config = try ConfigStore(context: context).loadRequired()
        #expect(throws: ToolError.self) {
            _ = try Linker.plan(context: context, config: config, label: "tok", repair: false)
        }
    }

    @Test func repairReplacesALinkWhoseTargetMovedAndDropsOneWhoseSourceIsGone() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let source = t.home.appendingPathComponent(".claude/CLAUDE.md")
        let dotfiles = t.home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try "moved".write(
            to: dotfiles.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(
            at: source, withDestinationURL: dotfiles.appendingPathComponent("CLAUDE.md"))
        let config = try ConfigStore(context: context).loadRequired()
        let plain = try Linker.plan(context: context, config: config, label: "spare", repair: false)
        #expect(plain.conflicts.count == 1)
        let applied = try link(context, repair: true)
        #expect(applied.replaced == 1)
        let target = real(dotfiles.appendingPathComponent("CLAUDE.md"))
        #expect(try destination(context, "CLAUDE.md") == target)
        #expect(Verifier.linkFacts(context: context, label: "spare").verdict == .ok)

        try FileManager.default.removeItem(at: source)
        let second = try link(context, repair: true)
        #expect(second.dropped == 1)
        #expect(try destination(context, "CLAUDE.md") == nil)
    }

    @Test func unlinkRemovesOnlyTheRecordedLinksAndKeepsAFile() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let folder = try accountFolder(context)
        // A listed path that is a regular file now: it is not the recorded link and stays.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("CLAUDE.md"))
        try "mine".write(
            to: folder.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let result = try Linker.removeLinks(
            context: context, label: "spare",
            expecting: HookRecord(context: context).linkState(for: "spare"))
        #expect(result.removed == 1 && result.kept == 1)
        #expect(
            try String(
                contentsOf: folder.appendingPathComponent("CLAUDE.md"), encoding: .utf8) == "mine")
        #expect(try destination(context, "settings.json") == nil)
        #expect(!HookRecord(context: context).isLinked("spare"))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aLinksManifestEntryNamingAPathOutsideAnAccountFolderNeverRemovesIt() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let outside = t.home.appendingPathComponent("keep.txt")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        let hooks = HookRecord(context: context)
        try hooks.saveLinks(
            label: "spare", entries: [LinkEntry(path: outside.path, target: "/x")], linked: true)
        _ = try Linker.removeLinks(
            context: context, label: "spare",
            expecting: HookRecord(context: context).linkState(for: "spare"))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func theManifestKeepsTheDefaultRecordAndOtherAccountsLinks() throws {
        let (t, context) = try setUp(folders: ["spare", "other"])
        defer { withExtendedLifetime(t) {} }
        _ = try link(context, "spare")
        _ = try link(context, "other")
        let hooks = HookRecord(context: context)
        #expect(hooks.isLinked("spare") && hooks.isLinked("other"))
        _ = try Linker.removeLinks(
            context: context, label: "spare",
            expecting: HookRecord(context: context).linkState(for: "spare"))
        #expect(!hooks.isLinked("spare") && hooks.isLinked("other"))
        #expect(hooks.entries(for: "other").count == 2)
        #expect(hooks.recorded() != nil)
        // The record call keeps the link data too.
        try hooks.record(.empty)
        #expect(hooks.isLinked("other"))
    }

    // MARK: Verifier

    @Test func aNeverLinkedFolderFailsAsNotLinked() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let facts = Verifier.linkFacts(context: context, label: "spare")
        #expect(facts.verdict == .notLinked)
        let account = try #require(
            try ConfigStore(context: context).loadRequired().account("spare"))
        let out = Verifier.failures(
            context: context, account: account, runner: ClaudeRunner(context: context),
            settingsIssue: nil, now: Date(), stopAtFirst: true)
        #expect(out.failures.first?.code == .notLinked)
        #expect(out.failures.first?.reason == "not linked")
        #expect(out.failures.first?.text.contains("Settings not shared.") == true)
    }

    @Test func aBrokenOrChangedLinkAndAMissingTargetFail() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        #expect(Verifier.linkFacts(context: context, label: "spare").verdict == .ok)
        // A link that points somewhere else.
        let folder = try accountFolder(context)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("CLAUDE.md"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("CLAUDE.md"),
            withDestinationURL: t.home.appendingPathComponent("elsewhere"))
        guard case .broken = Verifier.linkFacts(context: context, label: "spare").verdict else {
            Issue.record("a changed link passed")
            return
        }
        // A missing link, then a missing target.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("CLAUDE.md"))
        guard case .broken = Verifier.linkFacts(context: context, label: "spare").verdict else {
            Issue.record("a missing link passed")
            return
        }
        _ = try link(context, repair: true)
        #expect(Verifier.linkFacts(context: context, label: "spare").verdict == .ok)
        try FileManager.default.removeItem(at: t.home.appendingPathComponent(".claude/CLAUDE.md"))
        guard case .broken = Verifier.linkFacts(context: context, label: "spare").verdict else {
            Issue.record("a missing target passed")
            return
        }
    }

    @Test func addingAHookOrEditingSettingsPassesAndRemovingOneFails() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let settings = t.home.appendingPathComponent(".claude/settings.json")
        let hooks = HookRecord(context: context)
        // A status line and a second hook still pass.
        let more =
            #"{"statusLine":{"type":"command","command":"x"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"}]}],"Start":[{"hooks":[{"type":"command","command":"echo two"}]}]}}"#
        try more.write(to: settings, atomically: true, encoding: .utf8)
        #expect(hooks.currentState().issue == nil)
        // Removing the recorded hook fails.
        try #"{"hooks":{}}"#.write(to: settings, atomically: true, encoding: .utf8)
        #expect(hooks.currentState().issue == Messages.settingsChanged)
        // disableAllHooks fails.
        try
            #"{"disableAllHooks":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"}]}]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        #expect(hooks.currentState().issue == Messages.settingsChanged)
    }

    @Test func aWrongLoginAndAWrongFolderFail() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let account = try #require(
            try ConfigStore(context: context).loadRequired().account("spare"))
        let runner = ClaudeRunner(context: context)
        func codes() -> [StateCode] {
            Verifier.failures(
                context: context, account: account, runner: runner, settingsIssue: nil,
                now: Date(), stopAtFirst: false
            ).failures.map(\.code)
        }
        #expect(codes().isEmpty)
        try fakeAuth(t, context: context, label: "spare", email: "someone@example.com")
        #expect(codes() == [.wrongAccount])
        try fakeAuth(t, context: context, label: "spare", loggedIn: false)
        #expect(codes() == [.loginRejected])
        try fakeAuth(t, context: context, label: "spare", folder: "/somewhere/else/.claude")
        #expect(codes() == [.checkFailed])
    }

    // MARK: pick

    @Test func aLinkedFolderPickReturnsTheFolderRecipe() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let result = try pick(context)
        #expect(result.label == "spare")
        let dir = try accountFolder(context).path
        #expect(result.env == ["CLAUDE_CONFIG_DIR": dir])
        #expect(result.launchPrefix == "CLAUDE_CONFIG_DIR='\(dir)' ")
        #expect(result.args?.first == "--settings")
        #expect(!result.backgroundOnly)
        let path = try #require(result.args?.last)
        let launch = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                as? [String: Any])
        let env = try #require(launch["env"] as? [String: String])
        #expect(env == ["AGENT_BALANCER_ACCOUNT": "spare"])
        #expect(path.hasPrefix(LaunchFiles.rootURL(context: context).path + "/spare/l-"))
        #expect(t.fakeRecord("config-dirs.log").contains(dir))
    }

    @Test func aFolderPickWithAnInheritedTokenIsBackgroundOnly() throws {
        let (t, context) = try setUp(ambient: [ProtectedEnv.tokenVariable: "x"])
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let result = try pick(context)
        #expect(result.label == "spare")
        #expect(result.backgroundOnly)
    }

    @Test func aLauncherFolderPickKeepsTheFolderVariableOutOfUnsetEnv() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let result = try pick(context, PickRequest(caller: .launcher))
        #expect(result.env?["CLAUDE_CONFIG_DIR"] != nil)
        #expect(result.launchPrefix == nil)
        let unset = try #require(result.unsetEnv)
        #expect(!unset.contains("CLAUDE_CONFIG_DIR"))
        #expect(unset.contains("ANTHROPIC_API_KEY"))
    }

    @Test func aMissingOrBrokenLinkSkipsTheFolderAndLoginTokenAccountsAreStillPicked() throws {
        let tok = Account(label: "tok", kind: Kind.token, role: Role.pool)
        let (t, context) = try setUp(extra: [tok])
        defer { withExtendedLifetime(t) {} }
        _ = try t.makeTokenFile(label: "tok", secret: Canaries.oauthRealShape())
        // No links at all: the folder is skipped and the token account is picked.
        let first = try pick(context, PickRequest(model: nil))
        #expect(first.candidates.first { $0.label == "spare" }?.reason == "not linked")
        #expect(first.label == "tok")

        _ = try link(context)
        let folder = try accountFolder(context)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("CLAUDE.md"))
        let second = try pick(context, PickRequest(exclude: ["tok"]))
        #expect(second.label == nil)
        #expect(second.candidates.first { $0.label == "spare" }?.reason == "link broken")
    }

    @Test func aRemovedHookFailsEveryLinkedFolderAndEveryLoginAndTokenAccount() throws {
        let tok = Account(label: "tok", kind: Kind.token, role: Role.pool)
        let (t, context) = try setUp(extra: [tok])
        defer { withExtendedLifetime(t) {} }
        _ = try t.makeTokenFile(label: "tok", secret: Canaries.oauthRealShape())
        _ = try link(context)
        try #"{"hooks":{}}"#.write(
            to: t.home.appendingPathComponent(".claude/settings.json"), atomically: true,
            encoding: .utf8)
        let result = try pick(context)
        #expect(result.label == nil)
        let reasons = Dictionary(
            uniqueKeysWithValues: result.candidates.map { ($0.label, $0.reason) })
        #expect(reasons["spare"] == Messages.settingsChangedAll)
        #expect(reasons["tok"] == Messages.settingsChanged)
        let document = try #require(try StatusBuilder.rebuild(context: context))
        #expect(document.banner?.text == Messages.settingsChangedAll)
    }

    @Test func aCredentialNameInTheSharedSettingsSkipsTheFolderAndAHarmlessOneDoesNot() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let shared = t.home.appendingPathComponent(".claude/settings.json")
        let hooks = #""hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo one"}]}]}"#
        for name in ["CLAUDE_CODE_SUBAGENT_MODEL", "ANTHROPIC_MODEL"] {
            try "{\(hooks),\"env\":{\"\(name)\":\"v\"}}".write(
                to: shared, atomically: true, encoding: .utf8)
            let result = try pick(context)
            #expect(result.label == "spare", "\(name)")
        }
        for name in ["ANTHROPIC_BASE_URL", "CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            try "{\(hooks),\"env\":{\"\(name)\":\"v\"}}".write(
                to: shared, atomically: true, encoding: .utf8)
            let result = try pick(context)
            #expect(result.label == nil, "\(name)")
            let spare = result.candidates.first { $0.label == "spare" }
            #expect(spare?.reason == "settings carry an API key or key helper", "\(name)")
        }
    }

    @Test func aFolderThatSharesNoSettingsIsNotHitByAHookChange() throws {
        let (t, context) = try setUp(settings: nil)
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let shared = t.home.appendingPathComponent(".claude/settings.json")
        try Self.hookSettings.write(to: shared, atomically: true, encoding: .utf8)
        let hooks = HookRecord(context: context)
        try hooks.record(try hooks.readSettings())
        try FileManager.default.removeItem(at: shared)
        #expect(hooks.currentState().issue == Messages.settingsChanged)
        let result = try pick(context)
        #expect(result.label == "spare")
    }

    @Test func anAmbientConfigDirKeepsOnlyFolderAccountsForATypedCaller() throws {
        let login = Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
            expectedPlanTier: "max_20x")
        let (t, context) = try setUp(
            extra: [login], ambient: ["CLAUDE_CONFIG_DIR": "/somewhere/else"])
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let typed = try pick(context)
        #expect(typed.label == "spare")
        #expect(
            typed.candidates.first { $0.label == "main" }?.reason == "ambient CLAUDE_CONFIG_DIR set"
        )
        let launcher = try pick(context, PickRequest(caller: .launcher, exclude: ["spare"]))
        #expect(launcher.label == "main")
    }

    @Test func fullLoginOffersFolderAndLoginAccountsOnly() throws {
        let login = Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
            expectedPlanTier: "max_20x")
        let tok = Account(label: "tok", kind: Kind.token, role: Role.pool)
        let (t, context) = try setUp(extra: [login, tok])
        defer { withExtendedLifetime(t) {} }
        _ = try t.makeTokenFile(label: "tok", secret: Canaries.oauthRealShape())
        _ = try link(context)
        let result = try pick(context, PickRequest(fullLogin: true))
        let reasons = Dictionary(
            uniqueKeysWithValues: result.candidates.map { ($0.label, $0.reason) })
        #expect(reasons["tok"] == "token sessions have no connectors")
        #expect(result.label == "spare" || result.label == "main")
        #expect(result.candidates.filter(\.eligible).map(\.label).sorted() == ["main", "spare"])
    }

    @Test func aFolderRecipeFromAPathThatCannotBeQuotedIsRefused() throws {
        let (t, _) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let spaced = TestHome.wrapping(
            t.home.appendingPathComponent("a b"), fixtures: t.fixtures)
        try FileManager.default.createDirectory(at: spaced.home, withIntermediateDirectories: true)
        #expect(throws: ToolError.self) {
            _ = try FolderPaths.configDir(context: spaced.context, label: "spare")
        }
    }

    // MARK: The caller's own folder

    func login(_ label: String = "main") -> Account {
        Account(
            label: label, kind: Kind.login, role: Role.pool, email: "main@example.com",
            expectedPlanTier: "max_20x")
    }

    @Test func aJobFolderThatIsNotExactlyTheDefaultOneSkipsLoginAndToken() throws {
        let home = try TestHome()
        let base = home.home.path + "/.claude/jobs/"
        for (value, skipped) in [
            (base + "abc", false), (base + "abc/", true), (base + "../x", true),
            (base + "a/b", true), (home.home.path + "/.claude/jobs", true),
            ("/other/.claude/jobs/abc", true), ("relative/jobs/abc", true),
            (home.home.path + "/.agent-balancer/accounts/spare/.claude/jobs/abc", true),
        ] {
            let context = home.context(ambient: ["CLAUDE_JOB_DIR": value])
            let reason = SessionFolder.prefixlessReason(context: context)
            #expect((reason != nil) == skipped, "\(value)")
            if skipped { #expect(reason == "ambient session folder not default") }
        }
    }

    @Test func aDefaultJobFolderKeepsTheLoginAccountWithAnEmptyPrefix() throws {
        let (t, _) = try setUp(extra: [login()], settings: nil)
        defer { withExtendedLifetime(t) {} }
        let context = t.context(ambient: ["CLAUDE_JOB_DIR": t.home.path + "/.claude/jobs/abc"])
        let result = try pick(context)
        #expect(result.label == "main")
        #expect(result.launchPrefix == "")
    }

    @Test func aChatShellMustBeConfirmedAsTheDefaultFolderByItsSessionEntry() throws {
        let (t, _) = try setUp(extra: [login()], settings: nil)
        defer { withExtendedLifetime(t) {} }
        let sessions = t.home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        func context(pid: String?) -> ToolContext {
            var env = ["CLAUDE_CODE_CHILD_SESSION": "1"]
            if let pid { env["CLAUDE_PID"] = pid }
            return t.context(ambient: env)
        }
        // No entry yet.
        #expect(
            SessionFolder.prefixlessReason(context: context(pid: "4242"))
                == "chat folder not confirmed default")
        try "{}".write(
            to: sessions.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        #expect(SessionFolder.prefixlessReason(context: context(pid: "4242")) == nil)
        // A missing or non-numeric pid, and a pid that is also in a folder account, all skip.
        #expect(SessionFolder.prefixlessReason(context: context(pid: nil)) != nil)
        #expect(SessionFolder.prefixlessReason(context: context(pid: "42x2")) != nil)
        #expect(SessionFolder.prefixlessReason(context: context(pid: "")) != nil)
        let inFolder = try accountFolder(t.context).appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: inFolder, withIntermediateDirectories: true)
        try "{}".write(
            to: inFolder.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        #expect(SessionFolder.prefixlessReason(context: context(pid: "4242")) != nil)
        // The pick says so, and a folder account is still offered.
        _ = try link(t.context)
        let result = try pick(context(pid: "4242"))
        #expect(result.label == "spare")
        #expect(
            result.candidates.first { $0.label == "main" }?.reason
                == "chat folder not confirmed default")
    }

    @Test func aShellThatIsNotAChatAndALauncherAreUnchanged() throws {
        let (t, _) = try setUp(extra: [login()], settings: nil)
        defer { withExtendedLifetime(t) {} }
        #expect(SessionFolder.prefixlessReason(context: t.context) == nil)
        let chat = t.context(ambient: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        let result = try pick(chat, PickRequest(caller: .launcher, exclude: ["spare"]))
        #expect(result.label == "main")
    }

    @Test func doctorNamesTheSessionFolderByLabelOnly() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let config = try ConfigStore(context: context).loadRequired()
        #expect(SessionFolder.describe(context: context, config: config) == "default")
        let own = try accountFolder(context).path
        let inFolder = t.context(ambient: ["CLAUDE_CONFIG_DIR": own])
        #expect(SessionFolder.describe(context: inFolder, config: config) == "folder spare")
        let odd = t.context(ambient: ["CLAUDE_CONFIG_DIR": "/x"])
        #expect(SessionFolder.describe(context: odd, config: config) == "not confirmed")
    }

    // MARK: run

    @Test func runChecksAFolderAndAppliesItsRecipe() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        let service = PickService(context: context)
        // Refused while not linked, even by name, and nothing is written.
        #expect(throws: ToolError.self) {
            _ = try service.prepareRun(label: "spare", arguments: [])
        }
        #expect(!FileManager.default.fileExists(atPath: LaunchFiles.rootURL(context: context).path))
        _ = try link(context)
        let launch = try service.prepareRun(
            label: "spare", arguments: ["--model", "opus"], printOnly: true)
        let dir = try accountFolder(context).path
        #expect(launch.configDir?.path == dir)
        #expect(launch.line.hasPrefix("CLAUDE_CONFIG_DIR='\(dir)' claude --settings '"))
        #expect(launch.line.hasSuffix(" --model opus"))
        #expect(
            launch.arguments.first == "--settings"
                && launch.arguments.suffix(2) == ["--model", "opus"])
        #expect(t.fakeRecord("args.log").contains("auth status"))
    }

    // MARK: in use and status

    @Test func inUseCountsTheLiveEntriesOfTheFoldersOwnSessions() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let sessions = try accountFolder(context).appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let pid = Int(getpid())
        try #"{"sessionId":"s-folder-1","pid":\#(pid),"name":"work"}"#.write(
            to: sessions.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        try #"{"sessionId":"s-dead","pid":999999,"name":"old"}"#.write(
            to: sessions.appendingPathComponent("999999.json"), atomically: true, encoding: .utf8)
        let document = try #require(try StatusBuilder.rebuild(context: context))
        let row = try #require(document.accounts.first { $0.label == "spare" })
        #expect(row.inUse.count == 1)
        #expect(row.inUse.sessions.first?.id == "s-folder")
    }

    @Test func statusFillsLinkedAndConfigDirForFoldersOnly() throws {
        let (t, context) = try setUp(extra: [login("main")])
        defer { withExtendedLifetime(t) {} }
        var document = try #require(try StatusBuilder.rebuild(context: context))
        var folder = try #require(document.accounts.first { $0.label == "spare" })
        let main = try #require(document.accounts.first { $0.label == "main" })
        #expect(folder.linked == false)
        #expect(folder.configDir == "~/.agent-balancer/accounts/spare/.claude")
        #expect(main.linked == nil && main.configDir == nil)
        #expect(folder.error?.code == "not_linked")
        #expect(
            folder.error?.text
                == "Settings not shared. Run `agent-balancer link spare` in Terminal.")
        _ = try link(context)
        document = try #require(try StatusBuilder.rebuild(context: context))
        folder = try #require(document.accounts.first { $0.label == "spare" })
        #expect(folder.linked == true && folder.error?.code != "not_linked")
    }

    @Test func aNeverLinkedFolderAppendsOneNotLinkedEventAndLinkingRecovers() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try StatusBuilder.rebuild(context: context)
        _ = try StatusBuilder.rebuild(context: context)
        func events() throws -> [[String: Any]] {
            let data = try Data(
                contentsOf: context.dataRoot.appendingPathComponent("state/events.jsonl"))
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        let errors = try events().filter {
            $0["type"] as? String == "error" && $0["code"] as? String == "not_linked"
        }
        #expect(errors.count == 1)
        _ = try link(context)
        _ = try StatusBuilder.rebuild(context: context)
        let recovered = try events().filter { $0["type"] as? String == "recovered" }
        #expect(recovered.count == 1)
    }

    @Test func theBannerNamesAllOnlyWhenALinkedFolderIsAffected() throws {
        // Login only: no folder is affected.
        let (t, context) = try setUp(folders: [], extra: [login()], settings: Self.hookSettings)
        defer { withExtendedLifetime(t) {} }
        let hooks = HookRecord(context: context)
        try hooks.record(try hooks.readSettings())
        try #"{"hooks":{}}"#.write(
            to: t.home.appendingPathComponent(".claude/settings.json"), atomically: true,
            encoding: .utf8)
        let facts = try hooks.readSettings()
        var observations = StatusObservations()
        observations.settings = SettingsObservation(
            issue: hooks.currentState().kind, carriesKey: facts.carriesKey)
        let document = try #require(
            try StatusBuilder.rebuild(context: context, observations: observations))
        #expect(document.banner?.text == Messages.settingsChanged)
        #expect(!(document.banner?.text.contains("--all") ?? true))
    }

    @Test func removeFilesKeepsTheFolderAndItsLinksIntact() throws {
        let (t, context) = try setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try link(context)
        let result = try pick(context)
        #expect(result.label == "spare")
        let config = try ConfigStore(context: context).loadRequired()
        try HookRecord(context: context).saveLinks(label: "spare", entries: [], linked: false)
        _ = try TokenAccounts.removeAccount(context: context, label: "spare", config: config)
        let folder = try accountFolder(context)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(try destination(context, "CLAUDE.md") != nil)
        let leftovers = try TokenAccounts.hasLeftovers(context: context, label: "spare")
        #expect(!leftovers)
        #expect(try ConfigStore(context: context).loadRequired().account("spare") == nil)
    }
}
