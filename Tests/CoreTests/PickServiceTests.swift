import Foundation
import Testing

@testable import Core

@Suite struct PickServiceTests {
    func login(role: String = Role.pool) -> Account {
        Account(
            label: "main", kind: Kind.login, role: role, email: "main@example.com",
            expectedPlanTier: "max_20x")
    }

    func token(_ label: String) -> Account {
        Account(label: label, kind: Kind.token, role: Role.pool)
    }

    /// A home with the fake claude, a saved config, a hook record and a probe that reads 45.6
    /// percent of the week.
    func setUp(
        _ accounts: [Account], ambient: [String: String] = [:], hookRecord: Bool = true,
        tune: (inout Config) -> Void = { _ in }
    ) throws -> (TestHome, PickService) {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        try t.fakeProbe("ok.jsonl")
        var config = Config(accounts: accounts)
        config.fable.probe = false
        tune(&config)
        let context = t.context(ambient: ambient)
        try ConfigStore(context: context).save(config)
        if hookRecord { try HookRecord(context: context).record(.empty) }
        return (t, PickService(context: context))
    }

    func launchFiles(_ t: TestHome) -> [URL] {
        let root = LaunchFiles.rootURL(context: t.context)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    }

    func mode(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func json(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: Recipes

    @Test func aLoginPickWritesALaunchFileAndALease() throws {
        let (t, service) = try setUp([login()])
        let result = try service.pick(PickRequest())
        #expect(result.label == "main")
        #expect(result.env == [:])
        let path = try #require(result.args).last ?? ""
        #expect(result.args?.first == "--settings")
        #expect(result.launchPrefix == "")
        #expect(result.launchArgs == "--settings '\(path)'")
        #expect(result.unsetEnv == nil)
        #expect(!result.backgroundOnly)
        #expect(result.candidates.map(\.label) == ["main"])
        #expect(mode(URL(fileURLWithPath: path)) == 0o600)
        let env = try #require(json(URL(fileURLWithPath: path))["env"] as? [String: String])
        #expect(env == ["AGENT_BALANCER_ACCOUNT": "main"])
        #expect(path.hasPrefix(LaunchFiles.rootURL(context: t.context).path + "/main/l-"))
        let leases = t.context.dataRoot.appendingPathComponent("state/leases.json")
        #expect(mode(leases) == 0o600)
        let log = try String(
            contentsOf: t.context.dataRoot.appendingPathComponent("state/picks.log"),
            encoding: .utf8)
        #expect(log.contains(" default main l-"))
    }

    @Test func aTokenPickCopiesTheTokenOnlyIntoItsLaunchFile() throws {
        let (t, service) = try setUp([token("pool-a")])
        let secret = Canaries.oauth()
        let tokenFile = try t.makeTokenFile(label: "pool-a", secret: secret)
        let result = try service.pick(PickRequest(model: "sonnet"))
        #expect(result.label == "pool-a")
        let path = URL(fileURLWithPath: try #require(result.args).last ?? "")
        let env = try #require(json(path)["env"] as? [String: String])
        #expect(env[ProtectedEnv.tokenVariable] == secret)
        #expect(env[LaunchFiles.accountVariable] == "pool-a")
        #expect(mode(path) == 0o600)

        let answer = String(
            decoding: try PickResult.encoder().encode(result), as: UTF8.self)
        #expect(!answer.contains(secret))
        #expect(!answer.contains(ProtectedEnv.tokenVariable))
        let text = t.allText(skipping: tokenFile).replacingOccurrences(
            of: try String(contentsOf: path, encoding: .utf8), with: "")
        #expect(!text.contains(secret))
        // The probe child got the token only as the path of the token file.
        #expect(!t.fakeRecord("env-names.txt").contains(ProtectedEnv.tokenVariable))
        #expect(!t.fakeRecord("args.log").contains(secret))
    }

    @Test func aLauncherPickFillsUnsetEnvAndNoTypedStrings() throws {
        let (t, service) = try setUp([login()], ambient: [ProtectedEnv.configDirVariable: "/x"])
        let result = try service.pick(PickRequest(caller: .launcher))
        #expect(result.label == "main")
        #expect(result.launchPrefix == nil)
        #expect(result.launchArgs == nil)
        #expect(result.unsetEnv == Recipe.unsetNames)
        #expect(result.unsetEnv?.contains("CLAUDE_CONFIG_DIR") == true)
        #expect(result.args?.count == 2)
        #expect(!result.backgroundOnly)
        withExtendedLifetime(t) {}
    }

    @Test func theCallersSettingsAreMergedAfterTheAllowlist() throws {
        let (t, service) = try setUp([login()]) { $0.launch.envNames = ["MY_FLAG"] }
        let result = try service.pick(PickRequest(settings: "{\"env\":{\"MY_FLAG\":\"1\"}}"))
        let path = URL(fileURLWithPath: try #require(result.args).last ?? "")
        let env = try #require(json(path)["env"] as? [String: String])
        #expect(env == ["AGENT_BALANCER_ACCOUNT": "main", "MY_FLAG": "1"])
        withExtendedLifetime(t) {}
    }

    @Test func refusedSettingsExitOneAndWriteNothing() throws {
        let (t, service) = try setUp([login()])
        let secret = Canaries.oauth()
        for bad in [
            "{\"hooks\":{}}", "{\"env\":{\"MY_FLAG\":\"\(secret)\"}}", "[]",
            "{\"env\":{\"PATH\":\"/x\"}}",
        ] {
            do {
                _ = try service.pick(PickRequest(settings: bad))
                Issue.record("expected a refusal for \(bad)")
            } catch let e as ToolError {
                #expect(!e.message.contains(secret))
            }
        }
        #expect(launchFiles(t).isEmpty)
        let root = t.context.dataRoot
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("state/leases.json").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("state/picks.log").path))
        #expect(t.fakeRecord("args.log").isEmpty)
    }

    @Test func badFlagsExitOne() throws {
        let (t, service) = try setUp([login()])
        #expect(throws: ToolError.self) { try service.pick(PickRequest(model: "a b")) }
        #expect(throws: ToolError.self) { try service.pick(PickRequest(exclude: ["../x"])) }
        withExtendedLifetime(t) {}
    }

    // MARK: Ambient rule

    @Test func anAmbientConfigDirSkipsLoginAndTokenForATypedCaller() throws {
        let (t, service) = try setUp(
            [login(), token("pool-a")], ambient: [ProtectedEnv.configDirVariable: "/x"])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.env == nil && result.args == nil && result.launchArgs == nil)
        #expect(result.candidates.allSatisfy { $0.reason == "ambient CLAUDE_CONFIG_DIR set" })
        #expect(launchFiles(t).isEmpty)
        #expect(t.fakeRecord("args.log").isEmpty)
    }

    @Test func anUnreadableLeaseFileFailsThePickInsteadOfReadingAsNoLeases() throws {
        let (t, service) = try setUp([login()])
        let leases = t.context.dataRoot.appendingPathComponent("state/leases.json")
        try FileManager.default.createDirectory(
            at: leases.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: leases, atomically: true, encoding: .utf8)
        #expect(throws: ToolError.self) { try service.pick(PickRequest()) }
        #expect(try String(contentsOf: leases, encoding: .utf8) == "not json")
    }

    @Test func anAmbientProviderVariableCountsAsAnAmbientKey() throws {
        for name in ["CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_REFRESH"] {
            #expect(PickService.AmbientState([name: "x"]).key, "\(name)")
        }
        #expect(!PickService.AmbientState(["PATH": "/bin"]).key)
    }

    @Test func aLauncherUnsetsEveryProtectedNameTheCallerHolds() {
        let names = Recipe.unsetNames(
            env: [:], ambient: ["CLAUDE_CODE_USE_FOUNDRY": "1", "ANTHROPIC_CUSTOM_HEADERS": "x"])
        #expect(names.contains("ANTHROPIC_CUSTOM_HEADERS"))
        #expect(names.contains("CLAUDE_CODE_USE_FOUNDRY"))
        #expect(names.contains("CLAUDE_CODE_SIMPLE"))
        #expect(
            !Recipe.unsetNames(env: [ProtectedEnv.configDirVariable: "/x"])
                .contains(ProtectedEnv.configDirVariable))
    }

    /// The rows of the environment case table (docs/ARCHITECTURE.md section 4A.3).
    static let keyRows: [[String: String]] = [
        [ProtectedEnv.tokenVariable: "x"], ["ANTHROPIC_API_KEY": "x"],
        ["ANTHROPIC_AUTH_TOKEN": "x"],
        [ProtectedEnv.tokenVariable: "x", "ANTHROPIC_AUTH_TOKEN": "x"],
    ]

    @Test(arguments: PickServiceTests.keyRows)
    func anInheritedKeyMakesEveryTypedPickBackgroundOnly(ambient: [String: String]) throws {
        let (t, service) = try setUp([login()], ambient: ambient)
        let typed = try service.pick(PickRequest())
        #expect(typed.label == "main")
        #expect(typed.backgroundOnly)
        #expect(typed.launchPrefix == "")
        let launcher = try service.pick(PickRequest(caller: .launcher))
        #expect(launcher.label == "main")
        #expect(!launcher.backgroundOnly)
        #expect(launcher.unsetEnv == Recipe.unsetNames)
        #expect(launcher.launchArgs == nil)
        withExtendedLifetime(t) {}
    }

    @Test(arguments: PickServiceTests.keyRows)
    func aKeyTogetherWithAConfigDirSkipsTypedAndNotLauncher(ambient: [String: String]) throws {
        var both = ambient
        both[ProtectedEnv.configDirVariable] = "/x"
        let (t, service) = try setUp([login()], ambient: both)
        let typed = try service.pick(PickRequest())
        #expect(typed.label == nil)
        #expect(typed.candidates.allSatisfy { $0.reason == "ambient CLAUDE_CONFIG_DIR set" })
        let launcher = try service.pick(PickRequest(caller: .launcher))
        #expect(launcher.label == "main")
        #expect(!launcher.backgroundOnly)
        #expect(launcher.unsetEnv == Recipe.unsetNames)
        withExtendedLifetime(t) {}
    }

    @Test func nothingInheritedLetsEveryKindCompete() throws {
        let (t, service) = try setUp([login(), token("pool-a")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        let typed = try service.pick(PickRequest(dryRun: true))
        #expect(typed.candidates.allSatisfy { $0.eligible })
        #expect(!typed.backgroundOnly)
        let launcher = try service.pick(PickRequest(caller: .launcher, dryRun: true))
        #expect(launcher.candidates.allSatisfy { $0.eligible })
    }

    @Test func aLauncherInsideATokenSessionSkipsNothingAndUnsetsTheToken() throws {
        let (t, service) = try setUp(
            [login(), token("pool-a")],
            ambient: [ProtectedEnv.tokenVariable: "x", ProtectedEnv.configDirVariable: "/x"])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        let result = try service.pick(PickRequest(caller: .launcher))
        #expect(result.label != nil)
        #expect(result.candidates.allSatisfy { $0.eligible })
        #expect(result.unsetEnv?.contains(ProtectedEnv.tokenVariable) == true)
        #expect(result.unsetEnv?.contains(ProtectedEnv.configDirVariable) == true)
        #expect(!result.backgroundOnly)
    }

    // MARK: Fail closed per kind

    @Test func aMissingOrChangedHookRecordFailsLoginAndTokenAccounts() throws {
        let (t, service) = try setUp([login(), token("pool-a")], hookRecord: false)
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        let missing = try service.pick(PickRequest())
        #expect(missing.label == nil)
        #expect(missing.candidates.allSatisfy { $0.reason == Messages.hookRecordMissing })

        let hooks = HookRecord(context: t.context)
        try hooks.record(.empty)
        let claude = t.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try "{\"disableAllHooks\":true}".write(
            to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let changed = try service.pick(PickRequest())
        #expect(changed.label == nil)
        #expect(changed.candidates.allSatisfy { $0.reason == Messages.settingsChanged })
    }

    @Test(arguments: [
        "\"apiKeyHelper\":\"/bin/helper PLANTED\"",
        "\"env\":{\"ANTHROPIC_API_KEY\":\"PLANTED\"}",
        "\"env\":{\"ANTHROPIC_AUTH_TOKEN\":\"PLANTED\"}",
        "\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"PLANTED\"}",
    ])
    func keyNamesInSettingsSkipEveryAccountKind(member: String) throws {
        let (t, service) = try setUp([login(), token("pool-a")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        let planted = Canaries.apiKey()
        let claude = t.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try "{\(member.replacingOccurrences(of: "PLANTED", with: planted))}".write(
            to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        let reasons = Dictionary(
            uniqueKeysWithValues: result.candidates.map { ($0.label, $0.reason) })
        #expect(reasons["pool-a"] == "settings carry an API key or key helper")
        #expect(reasons["main"] == "settings carry an API key or key helper")
        let answer = String(decoding: try PickResult.encoder().encode(result), as: UTF8.self)
        #expect(!answer.contains(planted))
        let written = try launchFiles(t).map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(written.allSatisfy { !$0.contains(planted) })
        let log = try String(
            contentsOf: t.context.dataRoot.appendingPathComponent("state/picks.log"),
            encoding: .utf8)
        #expect(!log.contains(planted))
        #expect(!t.fakeRecord("args.log").contains(planted))
        let state = t.allText().replacingOccurrences(
            of: try String(contentsOf: claude.appendingPathComponent("settings.json")),
            with: "")
        #expect(!state.contains(planted))
    }

    func writeDefaultSettings(_ t: TestHome, _ body: String) throws {
        let claude = t.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try body.write(
            to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    @Test(arguments: [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_PROFILE", "ANTHROPIC_CONFIG_DIR",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
        "CLAUDE_SESSION_INGRESS_TOKEN_FILE", "CLAUDE_CONFIG_DIR",
    ])
    func aCredentialNameInSettingsEnvSkipsLoginAndTokenAccounts(name: String) throws {
        let (t, service) = try setUp([login(), token("pool-a")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try writeDefaultSettings(t, "{\"env\":{\"\(name)\":\"v\"}}")
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        let reasons = Dictionary(
            uniqueKeysWithValues: result.candidates.map { ($0.label, $0.reason) })
        #expect(reasons["main"] == "settings carry an API key or key helper", "\(name)")
        #expect(reasons["pool-a"] == "settings carry an API key or key helper", "\(name)")
        #expect(launchFiles(t).isEmpty)
    }

    @Test(arguments: [
        "CLAUDE_CODE_SUBAGENT_MODEL", "ANTHROPIC_MODEL", "CLAUDE_CODE_MAX_OUTPUT_TOKENS",
        "CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS",
    ])
    func aHarmlessNameInSettingsEnvSkipsNoAccount(name: String) throws {
        let (t, service) = try setUp([login(), token("pool-a")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try writeDefaultSettings(t, "{\"env\":{\"\(name)\":\"v\"}}")
        let dry = try service.pick(PickRequest(dryRun: true))
        #expect(dry.candidates.count == 2)
        #expect(dry.candidates.allSatisfy { $0.eligible }, "\(name)")
        let result = try service.pick(PickRequest())
        #expect(result.label != nil, "\(name)")
        #expect(!result.backgroundOnly)
    }

    @Test func aSettingsSourceNameInSettingsEnvSkipsEveryAccountAsHooksOff() throws {
        let (t, service) = try setUp([login(), token("pool-a")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try writeDefaultSettings(t, "{\"env\":{\"CLAUDE_CODE_REMOTE_SETTINGS_PATH\":\"/x\"}}")
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.allSatisfy { $0.reason == Messages.settingsChanged })
    }

    @Test func harmlessNamesAChatShellCarriesChangeNoTypedAnswer() throws {
        let ambient = [
            "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet", "ANTHROPIC_MODEL": "opus",
            "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SESSION_ID": "s-1",
            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/m.sock", "CLAUDE_CODE_MESSAGING_TOKEN": "m",
        ]
        let (t, service) = try setUp([login()], ambient: ambient)
        let typed = try service.pick(PickRequest())
        #expect(typed.label == "main")
        #expect(!typed.backgroundOnly)
        #expect(!PickService.AmbientState(ambient).key)
        withExtendedLifetime(t) {}
    }

    @Test(arguments: ProtectedEnv.storeNames)
    func aNameThatChoosesTheStoredLoginRefusesATypedPickAndWritesNothing(name: String) throws {
        let (t, service) = try setUp([login(), token("pool-a")], ambient: [name: ""])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        for request in [PickRequest(), PickRequest(dryRun: true)] {
            do {
                _ = try service.pick(request)
                Issue.record("a typed pick was not refused under \(name)")
            } catch let error as ToolError {
                #expect(error.message.contains(name))
            }
        }
        #expect(launchFiles(t).isEmpty)
        let state = t.context.dataRoot.appendingPathComponent("state")
        for file in ["leases.json", "picks.log"] {
            let path = state.appendingPathComponent(file).path
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        // A launcher removes the name from the child, so its pick goes ahead.
        let launcher = try service.pick(PickRequest(caller: .launcher))
        #expect(launcher.label != nil)
        #expect(launcher.unsetEnv?.contains(name) == true)
    }

    @Test(arguments: ProtectedEnv.settingsSourceNames)
    func aSettingsSourceNameRefusesATypedPickAndALauncherUnsetsIt(name: String) throws {
        let (t, service) = try setUp([login()], ambient: [name: "/elsewhere"])
        #expect(throws: ToolError.self) { try service.pick(PickRequest()) }
        #expect(launchFiles(t).isEmpty)
        let launcher = try service.pick(PickRequest(caller: .launcher))
        #expect(launcher.label == "main")
        #expect(launcher.unsetEnv?.contains(name) == true)
    }

    @Test func theDesignsExampleLaunchListsLoadAndAPickWithThemReturnsARecipe() throws {
        let (t, service) = try setUp([login()]) {
            $0.launch.settingsKeys = ["env", "crossSessionInbound"]
            $0.launch.envNames = ["CLAUDE_ROLE", "CLAUDE_CLIENT"]
        }
        let loaded = try ConfigStore(context: t.context).loadRequired()
        #expect(loaded.launch.envNames == ["CLAUDE_ROLE", "CLAUDE_CLIENT"])
        let settings =
            #"{"crossSessionInbound":"accept","env":{"CLAUDE_ROLE":"build-worker","CLAUDE_CLIENT":"card-1"}}"#
        let result = try service.pick(PickRequest(settings: settings))
        #expect(result.label == "main")
        #expect(result.launchArgs?.hasPrefix("--settings '") == true)
        let file = try json(URL(fileURLWithPath: try #require(result.args).last ?? ""))
        #expect(file["crossSessionInbound"] as? String == "accept")
        let env = try #require(file["env"] as? [String: String])
        #expect(
            env == [
                "AGENT_BALANCER_ACCOUNT": "main", "CLAUDE_ROLE": "build-worker",
                "CLAUDE_CLIENT": "card-1",
            ])
    }

    @Test func aTokenThatReadsLikeTheMainAccountIsStillOfferedAndOnlyWarned() throws {
        let (t, service) = try setUp([login(role: Role.main), token("pool-a")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        // The main account's reading is stored first, so the token's probe has one to match.
        let config = try ConfigStore(context: t.context).loadRequired()
        let main = try #require(config.account("main"))
        _ = Refresher(context: t.context, config: config).refresh(account: main, force: true)
        let result = try service.pick(PickRequest(model: "sonnet"))
        let pool = try #require(result.candidates.first { $0.label == "pool-a" })
        #expect(pool.eligible)
        #expect(!pool.reason.contains("main account"))
        let document = try #require(try StatusBuilder.rebuild(context: t.context))
        let warnings = document.accounts.first { $0.label == "pool-a" }?.warnings ?? []
        #expect(warnings.contains { $0.code == "possible_duplicate" })
    }

    @Test func aTokenFileThatIsOpenOrMissingIsRefused() throws {
        let (t, service) = try setUp([token("pool-a"), token("pool-b")])
        let file = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.allSatisfy { $0.reason == "no token saved" })
        #expect(launchFiles(t).isEmpty)
    }

    @Test func aMissingTokenFileIsRefused() throws {
        let (t, service) = try setUp([token("pool-a")])
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.first?.reason == "no token saved")
        #expect(launchFiles(t).isEmpty)
    }

    @Test func aTokenFileThatIsALinkIsRefused() throws {
        let (t, service) = try setUp([token("pool-a")])
        let file = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        let real = t.home.appendingPathComponent("real-token.json")
        try FileManager.default.moveItem(at: file, to: real)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.first?.reason == "no token saved")
        #expect(launchFiles(t).isEmpty)
    }

    @Test func aTokenFileOwnedByAnotherUserIsNotPrivate() {
        let other = TokenPaths.Facts(
            exists: true, isRegularFile: true, ownedByUser: false, mode: 0o600)
        #expect(!other.isPrivate)
        let mine = TokenPaths.Facts(
            exists: true, isRegularFile: true, ownedByUser: true, mode: 0o600)
        #expect(mine.isPrivate)
    }

    @Test func aTokenAccountWhoseLastProbeEndedInAnAuthErrorIsSkipped() throws {
        let (t, service) = try setUp([token("pool-a")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try t.fakeProbe("auth_error.jsonl")
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.first?.eligible == false)
        #expect(launchFiles(t).isEmpty)
    }

    @Test func aTokenFileWithoutATokenIsRefusedWhenTheLaunchFileIsWritten() throws {
        let (t, service) = try setUp([token("pool-a"), token("pool-b")])
        let a = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try "{\"env\":{}}".write(to: a, atomically: true, encoding: .utf8)
        _ = try t.makeTokenFile(label: "pool-b", secret: Canaries.oauth())
        let result = try service.pick(PickRequest())
        #expect(result.label == "pool-b")
        #expect(launchFiles(t).count == 1)
    }

    @Test func aRejectedLoginIsSkipped() throws {
        let (t, service) = try setUp([login()])
        try t.fakeFixture(auth: "logged_out")
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.first?.reason.hasPrefix("Login rejected") == true)
        #expect(launchFiles(t).isEmpty)
    }

    @Test func aFailedRefreshSkipsTheAccountAndNeverUsesZero() throws {
        let (t, service) = try setUp([token("pool-a")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try t.fake("probe.jsonl", "garbage\n")
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.first?.reason == "no weekly reading")
    }

    @Test func fullLoginLeavesTokenAccountsOut() throws {
        let (t, service) = try setUp([login(), token("pool-a")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        let result = try service.pick(PickRequest(fullLogin: true))
        #expect(result.label == "main")
        #expect(
            result.candidates.first { $0.label == "pool-a" }?.reason
                == "token sessions have no connectors")
    }

    @Test func excludeLeavesALabelOut() throws {
        let (t, service) = try setUp([login(), token("pool-a")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        let result = try service.pick(PickRequest(exclude: ["main"]))
        #expect(result.label == "pool-a")
        #expect(
            result.candidates.first { $0.label == "main" }?.reason == "excluded by caller")
    }

    // MARK: Leases and the lock

    @Test func twoPicksSecondsApartSpreadOverTwoAccounts() throws {
        let (t, service) = try setUp([token("pool-a"), token("pool-b")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        _ = try t.makeTokenFile(label: "pool-b", secret: Canaries.oauth())
        let first = try service.pick(PickRequest())
        let second = try service.pick(PickRequest())
        #expect(first.label == "pool-a")
        #expect(second.label == "pool-b")
        #expect(launchFiles(t).count == 2)
    }

    @Test func aDryRunWritesNoLeaseAndNoLaunchFile() throws {
        let (t, service) = try setUp([login()])
        let result = try service.pick(PickRequest(dryRun: true))
        #expect(result.label == "main")
        #expect(result.args == nil && result.launchArgs == nil && result.env == nil)
        #expect(result.dryRun)
        #expect(launchFiles(t).isEmpty)
        let state = t.context.dataRoot.appendingPathComponent("state")
        #expect(
            !FileManager.default.fileExists(
                atPath: state.appendingPathComponent("leases.json").path))
        #expect(
            !FileManager.default.fileExists(atPath: state.appendingPathComponent("picks.log").path))
        let data = try PickResult.encoder().encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["dryRun"] as? Bool == true)
    }

    @Test func aPickReasonIsScrubbedBeforeThePickLogKeepsIt() throws {
        let t = try TestHome()
        let reason =
            "Picked for pat.example@example.com, j\u{F6}s\u{E9}@example.com and pat@mailhost."
        PickService(context: t.context).logPick(
            time: Date(), model: "default", label: "pool-a", leaseId: "l-0a0b0c0d", reason: reason,
            writer: NoFollowWriter(root: t.context.dataRoot))
        let log = try String(
            contentsOf: t.context.dataRoot.appendingPathComponent("state/picks.log"),
            encoding: .utf8)
        #expect(log.contains(" default pool-a l-0a0b0c0d Picked for [email], [email] and [email]."))
        #expect(!log.contains("@"))
    }

    /// Both passes run before the 300-scalar cap: a token-shaped run is redacted, and an address
    /// the cap would cut leaves no piece of itself.
    @Test func aPickReasonIsScrubbedBeforeItIsCut() throws {
        let t = try TestHome()
        let token = Canaries.oauth()
        let filler = String(repeating: "x", count: 290)
        let reasons = ["Picked with \(token) in its text.", filler + " pat.example@example.com"]
        for reason in reasons {
            PickService(context: t.context).logPick(
                time: Date(), model: "default", label: "pool-a", leaseId: nil, reason: reason,
                writer: NoFollowWriter(root: t.context.dataRoot))
        }
        let log = try String(
            contentsOf: t.context.dataRoot.appendingPathComponent("state/picks.log"),
            encoding: .utf8)
        let lines = log.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first?.hasSuffix(" pool-a - Picked with [redacted] in its text.") == true)
        #expect(lines.last?.hasSuffix(" pool-a - \(filler) [email]") == true)
        #expect(!log.contains(token))
        #expect(!log.contains("pat"))
    }

    @Test func aHeldPickLockGivesPickBusy() throws {
        let (t, service) = try setUp([login()])
        var quick = service
        quick.lockWaitSeconds = 0.2
        let held = try #require(
            try NoFollowWriter(root: t.context.dataRoot).acquireLock(
                folders: Layout.locksFolders, name: Layout.pickLockName, wait: 1))
        defer { held.release() }
        do {
            _ = try quick.pick(PickRequest())
            Issue.record("expected pick busy")
        } catch let e as ToolError {
            #expect(e.message == "pick busy")
        }
        #expect(launchFiles(t).isEmpty)
    }

    @Test func aLeaseDatedInTheFutureIsDropped() throws {
        let (t, service) = try setUp([token("pool-a"), token("pool-b")])
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        _ = try t.makeTokenFile(label: "pool-b", secret: Canaries.oauth())
        let future = Lease(
            id: "l-00000000", label: "pool-a", model: "x", at: Date().addingTimeInterval(3_600))
        try LeaseStore(context: t.context).save([future])
        let result = try service.pick(PickRequest())
        #expect(result.label == "pool-a")
        let kept = try LeaseStore(context: t.context).current(
            now: Date().addingTimeInterval(7_200), leaseMinutes: 600)
        #expect(kept.map(\.label) == ["pool-a"])
    }

    @Test func nothingEligibleExitsTwoShapeWithNoFiles() throws {
        let (t, service) = try setUp([login()]) { $0.picker.limitedAtPercent = 40 }
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(!result.picked)
        let data = try PickResult.encoder().encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["label", "env", "args", "launchPrefix", "launchArgs", "unsetEnv"] {
            #expect(object[key] is NSNull, "\(key)")
        }
        #expect(object["backgroundOnly"] as? Bool == false)
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(launchFiles(t).isEmpty)
    }

    @Test func aReplyWithoutTheWeeklyUseNeverFreshensTheMainAccount() throws {
        let (t, service) = try setUp([login(role: Role.main)])
        // A stored reading past the age limit, well under the reserve line.
        let now = Date()
        let old = now.addingTimeInterval(-1_200)
        try ReadingStore(context: t.context).save(
            Reading(
                readAt: old,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 40, resetsAt: now.addingTimeInterval(3 * 86_400), readAt: old)
                ]), label: "main")
        // The reply carries the 5-hour use and a weekly entry with no value.
        let seconds = Int(now.timeIntervalSince1970)
        try t.fake(
            "probe.jsonl",
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
                + "\"five_hour\":{\"utilization\":0.1,\"resetsAt\":\(seconds + 3_600)},"
                + "\"seven_day\":{\"resetsAt\":\(seconds + 3 * 86_400)}}}}\n")
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.map(\.reason) == ["stale reading, refresh failed"])
        #expect(launchFiles(t).isEmpty)
    }

    @Test func aMainAccountWhoseRepliesNeverNameFiveHourIsRefused() throws {
        let (t, service) = try setUp([login(role: Role.main)])
        // Nothing is stored, and the reply carries only the weekly use.
        let seconds = Int(Date().timeIntervalSince1970)
        try t.fake(
            "probe.jsonl",
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\","
                + "\"unifiedWindows\":{\"seven_day\":{\"utilization\":0.1,\"resetsAt\":"
                + "\(seconds + 3 * 86_400)}}}}\n")
        let missing = "No 5-hour reading, which the main account needs."
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.map(\.reason) == [missing])
        #expect(result.reason == "No account has room. main: " + missing)
        #expect(launchFiles(t).isEmpty)
        #expect(try LeaseStore(context: t.context).current(now: Date(), leaseMinutes: 600).isEmpty)
        let stored = try #require(try ReadingStore(context: t.context).load(label: "main"))
        #expect(stored.sevenDay?.usedPercent == 10)
        #expect(stored.fiveHour == nil)
    }

    @Test func aPickThatNamesNoPlacedModelSkipsAMainAccountThatRefusesFableLaunches() throws {
        var main = login(role: Role.main)
        main.fable = AccountFable(allowLaunches: false)
        let (t, service) = try setUp([main])
        // Weekly use 10 percent, its reset 3 days out, and a 5-hour window.
        let seconds = Int(Date().timeIntervalSince1970)
        try t.fake(
            "probe.jsonl",
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\","
                + "\"unifiedWindows\":{\"five_hour\":{\"utilization\":0.1,\"resetsAt\":"
                + "\(seconds + 3_600)},\"seven_day\":{\"utilization\":0.1,\"resetsAt\":"
                + "\(seconds + 3 * 86_400)}}}}\n")
        let skipped =
            "No account has room. main: Model unknown, and Fable launches not allowed on the main account."
        for request in [PickRequest(dryRun: true), PickRequest(model: "default", dryRun: true)] {
            let result = try service.pick(request)
            #expect(result.label == nil, "\(request.model ?? "none")")
            #expect(result.reason == skipped, "\(request.model ?? "none")")
        }
        let haiku = try service.pick(PickRequest(model: "haiku", dryRun: true))
        #expect(haiku.label == "main")
        #expect(!haiku.reason.contains("Model unknown"))
    }

    @Test func aStoredReadingThatCannotBeReadCountsAsNoFiveHourWindow() throws {
        let missing = "No 5-hour reading, which the main account needs."
        for role in [Role.pool, Role.main] {
            for damage in ["a file that does not decode", "a 5-hour use outside 0 to 100"] {
                let (t, service) = try setUp([login(role: role)])
                let store = ReadingStore(context: t.context)
                let now = Date()
                let weeklyReset = Int(now.timeIntervalSince1970) + 3 * 86_400
                if damage == "a file that does not decode" {
                    try NoFollowWriter(root: t.context.dataRoot).put(
                        Data("{not json".utf8), folders: Layout.readingsFolders,
                        name: Layout.readingName("main"))
                } else {
                    // Stored 20 minutes ago, so the pick probes again.
                    let old = now.addingTimeInterval(-1_200)
                    try store.save(
                        Reading(
                            readAt: old,
                            windows: [
                                WindowName.sevenDay: WindowReading(
                                    usedPercent: 10,
                                    resetsAt: Date(timeIntervalSince1970: Double(weeklyReset)),
                                    readAt: old),
                                WindowName.fiveHour: WindowReading(
                                    usedPercent: 150, resetsAt: now.addingTimeInterval(3_600),
                                    readAt: old),
                            ]), label: "main")
                }
                try t.fake(
                    "probe.jsonl",
                    "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\","
                        + "\"unifiedWindows\":{\"seven_day\":{\"utilization\":0.1,\"resetsAt\":"
                        + "\(weeklyReset)}}}}\n")
                let result = try service.pick(PickRequest(dryRun: true))
                if role == Role.main {
                    #expect(result.label == nil, "\(damage)")
                    #expect(result.candidates.map(\.reason) == [missing], "\(damage)")
                } else {
                    #expect(result.label == "main", "\(damage)")
                    #expect(result.reason.hasSuffix(" 5-hour use unknown."), "\(damage)")
                }
                let stored = try #require(try store.load(label: "main"))
                #expect(stored.fiveHour == nil, "\(damage)")
                #expect(stored.sevenDay?.usedPercent == 10, "\(damage)")
            }
        }
    }

    @Test(arguments: ["null", "6 days out", "2 days out"])
    func aHeldWeeklyWindowNeverKeepsLessUseThanTheReplyGives(weeklyReset: String) throws {
        let (t, service) = try setUp([login(role: Role.main)])
        // Stored 20 minutes ago: 40 percent of the week, resetting in 3 days, well under the
        // reserve line, and 10 percent of the 5 hours.
        let now = Date()
        let seconds = Int(now.timeIntervalSince1970)
        func minute(_ s: Int) -> Date {
            Date(timeIntervalSince1970: (Double(s) / 60).rounded() * 60)
        }
        let old = now.addingTimeInterval(-1_200)
        try ReadingStore(context: t.context).save(
            Reading(
                readAt: old,
                windows: [
                    WindowName.sevenDay: WindowReading(
                        usedPercent: 40, resetsAt: minute(seconds + 3 * 86_400), readAt: old),
                    WindowName.fiveHour: WindowReading(
                        usedPercent: 10, resetsAt: minute(seconds + 3_600), readAt: old),
                ]), label: "main")
        // The reply says 95 percent of the week, with no reset time or another one.
        let resets = [
            "null": "null", "6 days out": "\(seconds + 6 * 86_400)",
            "2 days out": "\(seconds + 2 * 86_400)",
        ]
        try t.fake(
            "probe.jsonl",
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{"
                + "\"five_hour\":{\"utilization\":0.1,\"resetsAt\":\(seconds + 3_600)},"
                + "\"seven_day\":{\"utilization\":0.95,\"resetsAt\":\(resets[weeklyReset] ?? "")}}}}\n"
        )
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.first?.reason.hasPrefix("Limited until") == true)
        let stored = try ReadingStore(context: t.context).load(label: "main")
        #expect(stored?.sevenDay?.usedPercent == 95)
        #expect(stored?.sevenDay?.resetsAt == minute(seconds + 3 * 86_400))
        #expect(launchFiles(t).isEmpty)
    }

    @Test func anAccountWhoseProbeNeverBeganAtTheDeadlineKeepsItsStatus() throws {
        let accounts = (0..<10).map { token("pool-\($0)") }
        let (t, service) = try setUp(accounts) { $0.picker.deadlineSeconds = 1 }
        let store = ReadingStore(context: t.context)
        let old = Date().addingTimeInterval(-7_200)
        for account in accounts {
            _ = try t.makeTokenFile(label: account.label, secret: Canaries.oauth())
            try store.save(
                Reading(
                    readAt: old,
                    windows: [
                        WindowName.sevenDay: WindowReading(
                            usedPercent: 10, resetsAt: Date().addingTimeInterval(86_400 * 3),
                            readAt: old)
                    ]), label: account.label)
        }
        // Every reading is stale and every probe outlasts the deadline, so 8 probes begin and
        // the other 2 accounts wait for a thread until the deadline passes.
        try t.fake("delay", "3")
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.allSatisfy { $0.reason == "stale reading, refresh failed" })
        // Let the probes that began end before looking.
        let until = Date().addingTimeInterval(20)
        var starts: [String] = []
        while Date() < until {
            let records = t.fakeLines("spans.log")
            starts = records.filter { $0.hasPrefix("start ") }.map { String($0.dropFirst(6)) }
            if starts.count >= Refresher.maxProbesAtOnce && records.count == 2 * starts.count {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let begun = Set(starts)
        #expect(begun.count == Refresher.maxProbesAtOnce)
        // Only a probe that ran is recorded: an error event and check_failed for those, nothing
        // for the accounts whose probe never began.
        let events = try EventLog(context: t.context).answer(EventsQuery()).events
        let errors = Set(events.filter { $0.type == EventType.error }.map(\.label))
        #expect(errors == begun)
        let status = try JSONSerialization.jsonObject(
            with: Data(
                contentsOf: t.context.dataRoot.appendingPathComponent("state/status.json")))
        let rows = (status as? [String: Any])?["accounts"] as? [[String: Any]] ?? []
        #expect(rows.count == accounts.count)
        for row in rows {
            let label = row["label"] as? String ?? ""
            let code = (row["error"] as? [String: Any])?["code"] as? String
            #expect(code == (begun.contains(label) ? "check_failed" : nil), "\(label)")
        }
    }

    @Test func aProbeThatMissesTheDeadlineIsSkippedAsStale() throws {
        let (t, service) = try setUp([token("pool-a"), token("pool-b")]) {
            $0.picker.deadlineSeconds = 1
        }
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        _ = try t.makeTokenFile(label: "pool-b", secret: Canaries.oauth())
        // Both readings are old, so both need a probe, and the fake claude sleeps past the deadline.
        let old = Date().addingTimeInterval(-7_200)
        let store = ReadingStore(context: t.context)
        for label in ["pool-a", "pool-b"] {
            try store.save(
                Reading(
                    readAt: old,
                    windows: [
                        WindowName.sevenDay: WindowReading(
                            usedPercent: 10, resetsAt: Date().addingTimeInterval(86_400 * 3),
                            readAt: old)
                    ]), label: label)
        }
        try t.fake("delay", "4")
        let started = Date()
        let result = try service.pick(PickRequest())
        #expect(Date().timeIntervalSince(started) < 3.5)
        #expect(result.label == nil)
        #expect(result.candidates.count == 2)
        #expect(result.candidates.allSatisfy { $0.reason == "stale reading, refresh failed" })
        #expect(launchFiles(t).isEmpty)
    }

    @Test func aLaunchPathThatCannotBeTypedLeavesNoFileAndNoLease() throws {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        try t.fakeProbe("ok.jsonl")
        var config = Config(accounts: [token("pool-a")])
        config.fable.probe = false
        // A quote in the home folder puts a quote in the launch file path.
        let quoted = t.home.appendingPathComponent("it's")
        try FileManager.default.createDirectory(at: quoted, withIntermediateDirectories: true)
        let context = ToolContext(home: quoted, ambient: [:])
        try FileManager.default.createDirectory(
            at: quoted.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: t.fakePath, to: quoted.appendingPathComponent(".local/bin/claude"))
        try FileManager.default.copyItem(
            at: t.home.appendingPathComponent(".ab-fake"),
            to: quoted.appendingPathComponent(".ab-fake"))
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        let quotedHome = TestHome.wrapping(quoted, fixtures: t.fixtures)
        _ = try quotedHome.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        let service = PickService(context: context)
        #expect(throws: ToolError.self) { try service.pick(PickRequest()) }
        #expect(launchFiles(quotedHome).isEmpty)
        let state = context.dataRoot.appendingPathComponent("state")
        #expect(
            !FileManager.default.fileExists(
                atPath: state.appendingPathComponent("leases.json").path))
        // A launcher has no typed string, so the same path works.
        let launcher = try service.pick(PickRequest(caller: .launcher))
        #expect(launcher.label == "pool-a")
    }

    // MARK: Fable

    @Test func aFablePickRunsAFableProbeAndAnotherModelDoesNot() throws {
        let (t, service) = try setUp([token("pool-a")]) { $0.fable.probe = true }
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try t.fakeProbe("ok.jsonl", model: "haiku")
        try t.fakeProbe("fable.jsonl", model: "fable")
        let plain = try service.pick(PickRequest(model: "opus"))
        #expect(plain.label == "pool-a")
        #expect(!t.fakeRecord("models.log").contains("fable"))
        // A model the tool cannot place starts no Fable probe and says the room was not checked.
        for request in [PickRequest(dryRun: true), PickRequest(model: "default", dryRun: true)] {
            let unknown = try service.pick(request)
            #expect(unknown.label == "pool-a", "\(request.model ?? "none")")
            #expect(
                unknown.reason.hasSuffix(" Model unknown, so Fable room not checked."),
                "\(request.model ?? "none")")
            #expect(!t.fakeRecord("models.log").contains("fable"), "\(request.model ?? "none")")
        }
        let fable = try service.pick(PickRequest(model: "fable"))
        #expect(fable.label == "pool-a")
        #expect(t.fakeRecord("models.log").contains("fable"))
        #expect(fable.reason.contains("Fable at least 69% of cap left."))
    }

    @Test func aFableRecheckHappensWhenAllModelsUseRoseByFivePoints() throws {
        let (t, service) = try setUp([token("pool-a")]) { $0.fable.probe = true }
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try t.fakeProbe("ok.jsonl", model: "haiku")
        try t.fakeProbe("fable.jsonl", model: "fable")
        _ = try service.pick(PickRequest(model: "fable"))
        let probes = t.fakeLines("models.log").filter { $0 == "fable" }.count
        #expect(probes == 1)

        let store = ReadingStore(context: t.context)
        var stored = try #require(try store.load(label: "pool-a"))
        // The Fable reading was taken at a lower weekly use, and the last try was 20 minutes ago.
        let weekly = stored.sevenDay?.usedPercent ?? 0
        stored.fable?.weeklyUsedPercentAtRead = weekly - 6
        stored.fableProbedAt = Date().addingTimeInterval(-1_200)
        try store.save(stored, label: "pool-a")
        _ = try service.pick(PickRequest(model: "fable"))
        #expect(t.fakeLines("models.log").filter { $0 == "fable" }.count == 2)
    }

    @Test func aFableReadingFromTheLastDayGetsNoProbeAndAnOlderOneGetsOne() throws {
        let (t, service) = try setUp([token("pool-a")]) { $0.fable.probe = true }
        _ = try t.makeTokenFile(label: "pool-a", secret: Canaries.oauth())
        try t.fakeProbe("ok.jsonl", model: "haiku")
        try t.fakeProbe("fable.jsonl", model: "fable")
        func probes() -> Int { t.fakeLines("models.log").filter { $0 == "fable" }.count }
        // No reading yet: one probe.
        _ = try service.pick(PickRequest(model: "fable"))
        #expect(probes() == 1)
        // A reading from moments ago: no probe.
        _ = try service.pick(PickRequest(model: "fable"))
        #expect(probes() == 1)
        // A reading from two days ago: one probe.
        let store = ReadingStore(context: t.context)
        var stored = try #require(try store.load(label: "pool-a"))
        stored.fableProbedAt = Date().addingTimeInterval(-2 * 86_400)
        try store.save(stored, label: "pool-a")
        _ = try service.pick(PickRequest(model: "fable"))
        #expect(probes() == 2)
    }

    @Test func aNeverLinkedFolderIsSkippedAsNotLinked() throws {
        let folder = Account(label: "f", kind: Kind.folder, role: Role.pool)
        let (t, service) = try setUp([folder])
        let result = try service.pick(PickRequest())
        #expect(result.label == nil)
        #expect(result.candidates.first?.reason == "not linked")
        #expect(!t.home.path.isEmpty)
    }
}
