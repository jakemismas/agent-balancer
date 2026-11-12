import Foundation
import Testing

@testable import Core

/// `run` never opens the default folder's settings file: it relies on the verdict a reader saved
/// and the file's stamp, and it refuses before writing anything when either does not hold.
@Suite struct RunSettingsVerdictTests {
    let hookBody =
        #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo a"}]}]}}"#

    func login() -> Account {
        Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
            expectedPlanTier: "max_20x")
    }

    func token() -> Account { Account(label: "pool-a", kind: Kind.token, role: Role.pool) }

    func settingsURL(_ t: TestHome) -> URL {
        t.home.appendingPathComponent(".claude/settings.json")
    }

    func writeSettings(_ t: TestHome, _ body: String) throws {
        let url = settingsURL(t)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A configured home whose record and verdict match `body` (no settings file when nil).
    func setUp(
        settings body: String? = nil, accounts: [Account]? = nil,
        ambient: [String: String] = [:]
    ) throws -> (TestHome, PickService) {
        let t = try TestHome()
        try t.installFake()
        try t.fakeFixture(auth: "logged_in")
        var config = Config(accounts: accounts ?? [login(), token()])
        config.fable.probe = false
        try ConfigStore(context: t.context).save(config)
        if let body { try writeSettings(t, body) }
        let hooks = HookRecord(context: t.context)
        try hooks.record(try hooks.readSettings())
        _ = try hooks.readSettings()
        return (t, PickService(context: t.context(ambient: ambient)))
    }

    func installToken(_ t: TestHome) throws {
        _ = try TokenAccounts.install(
            context: t.context, label: "pool-a", token: Canaries.oauthRealShape())
    }

    /// Every file and folder under the data folder, as relative paths.
    func tree(_ t: TestHome) -> [String] {
        let root = t.context.dataRoot
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return (walker.allObjects as? [String] ?? []).sorted()
    }

    func startedClaude(_ t: TestHome) -> Bool {
        t.fakeRecord("args.log").contains("--settings")
    }

    /// Asserts a refusal that wrote nothing at all.
    func refuses(
        _ service: PickService, _ t: TestHome, label: String = "main", arguments: [String] = [],
        printOnly: Bool = false, code: StateCode? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let before = tree(t)
        do {
            _ = try service.prepareRun(label: label, arguments: arguments, printOnly: printOnly)
            Issue.record("run was not refused", sourceLocation: sourceLocation)
        } catch let error as ToolError {
            if let code { #expect(error.code == code, sourceLocation: sourceLocation) }
        } catch {
            Issue.record("unexpected error", sourceLocation: sourceLocation)
        }
        #expect(tree(t) == before, "a refusal wrote something", sourceLocation: sourceLocation)
        #expect(!startedClaude(t), sourceLocation: sourceLocation)
    }

    // MARK: D1, the verdict

    @Test func aFreshVerdictLetsRunProceedAndWritesAPicksLogLine() throws {
        let (t, service) = try setUp(settings: hookBody)
        let launch = try service.prepareRun(label: "main", arguments: [])
        let log = try String(
            contentsOf: t.context.dataRoot.appendingPathComponent("state/picks.log"),
            encoding: .utf8)
        #expect(log.contains(" main \(launch.leaseId) "))
    }

    @Test func runWorksWithAnUnreadableSettingsFileWhileTheVerdictMatchesItsStamp() throws {
        let (t, service) = try setUp(settings: hookBody)
        let url = settingsURL(t)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        // The mode change moved the change time, so a reader's verdict is saved for the new stamp.
        let stamp = try SettingsStamp.take(url)
        // A reader that cannot open the file saves an unreadable verdict; a later reader that can
        // see it replaces that, which is what saving the facts for this stamp stands for here.
        HookRecord(context: t.context).saveVerdict(
            stamp: stamp, facts: try HookRecord.parse(Data(hookBody.utf8)))
        _ = try service.prepareRun(label: "main", arguments: [])
    }

    @Test func aSameSizeEditWithTheModificationTimePutBackStillRefuses() throws {
        let (t, service) = try setUp(settings: #"{"a":1}"#)
        let url = settingsURL(t)
        var before = stat()
        #expect(stat(url.path, &before) == 0)
        let stampBefore = try SettingsStamp.take(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(#"{"a":2}"#.utf8))
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
        let stampAfter = try SettingsStamp.take(url)
        // Size, inode and modification time are the same again; only the change time differs.
        #expect(stampAfter.target.size == stampBefore.target.size)
        #expect(stampAfter.target.inode == stampBefore.target.inode)
        #expect(stampAfter.target.mtimeNanos == stampBefore.target.mtimeNanos)
        #expect(stampAfter != stampBefore)
        refuses(service, t, code: .settingsChanged)
    }

    @Test func aMissingOrBrokenVerdictRefuses() throws {
        let (t, service) = try setUp(settings: hookBody)
        let seen = t.context.dataRoot.appendingPathComponent("state/settings-seen.json")
        let good = try String(contentsOf: seen, encoding: .utf8)
        func put(_ text: String) throws {
            try text.write(to: seen, atomically: true, encoding: .utf8)
        }
        let hash = try #require(
            good.range(of: #"[0-9a-f]{64}"#, options: .regularExpression).map { String(good[$0]) })
        try put(good.replacingOccurrences(of: hash, with: "not-a-hash"))
        refuses(service, t, code: .settingsChanged)
        try put(good.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"))
        refuses(service, t, code: .settingsChanged)
        try put(good.replacingOccurrences(of: "\"readable\":true", with: "\"readable\":false"))
        refuses(service, t, code: .settingsChanged)
        try put("not json")
        refuses(service, t, code: .settingsChanged)
        try FileManager.default.removeItem(at: seen)
        refuses(service, t, code: .settingsChanged)
        // Putting the good verdict back lets run through again.
        try put(good)
        _ = try service.prepareRun(label: "main", arguments: [])
    }

    @Test func aReaderThatCannotParseTheFileRecordsAnUnreadableVerdictThatRefuses() throws {
        let (t, service) = try setUp(settings: hookBody)
        try writeSettings(t, "not json")
        #expect(throws: (any Error).self) { _ = try HookRecord(context: t.context).readSettings() }
        refuses(service, t, code: .settingsChanged)
    }

    @Test func aReplacedSymlinkAMovedFileAndANonRegularPathAllRefuse() throws {
        let (t, service) = try setUp(settings: hookBody)
        let url = settingsURL(t)
        let other = t.home.appendingPathComponent("elsewhere.json")
        try hookBody.write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        refuses(service, t, code: .settingsChanged)
        // A reader sees the link and saves its verdict; the same link then passes.
        _ = try HookRecord(context: t.context).readSettings()
        _ = try service.prepareRun(label: "main", arguments: [])
        // Retargeting the link to another file refuses again.
        let second = t.home.appendingPathComponent("second.json")
        try hookBody.write(to: second, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: second)
        refuses(service, t, code: .settingsChanged)
    }

    @Test func aFolderOrADanglingLinkNeverPassesEvenWithAVerdictSavedForIt() throws {
        let (t, service) = try setUp(settings: nil)
        let url = settingsURL(t)
        let hooks = HookRecord(context: t.context)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        hooks.saveVerdict(stamp: try SettingsStamp.take(url), facts: .empty)
        refuses(service, t, code: .settingsChanged)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: url, withDestinationURL: t.home.appendingPathComponent("gone.json"))
        // A reader sees a missing file as no settings and saves that, but the path is not usable.
        _ = try hooks.readSettings()
        refuses(service, t, code: .settingsChanged)
    }

    @Test func deletingTheFileAfterAVerdictRefusesAndAnAbsentVerdictPasses() throws {
        let (t, service) = try setUp(settings: hookBody)
        try FileManager.default.removeItem(at: settingsURL(t))
        refuses(service, t, code: .settingsChanged)
        _ = try? HookRecord(context: t.context).readSettings()
        // No settings file now means no hooks, and the record still lists one: changed.
        refuses(service, t, code: .settingsChanged)
        let (u, serviceU) = try setUp(settings: nil)
        _ = try serviceU.prepareRun(label: "main", arguments: [])
        #expect(!tree(u).isEmpty)
    }

    @Test func aHookRemovedFromTheRecordSideIsCaughtWithNoSettingsRead() throws {
        let (t, service) = try setUp(settings: hookBody)
        // The record is rewritten as if it held another hook; the settings and verdict are as before.
        let other = try HookRecord.parse(
            Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}"#.utf8))
        try HookRecord(context: t.context).record(other)
        refuses(service, t, code: .settingsChanged)
        try FileManager.default.removeItem(
            at: t.context.dataRoot.appendingPathComponent("links.json"))
        refuses(service, t, code: .settingsChanged)
    }

    @Test func aStoredKeyRefusesATokenAccountOnly() throws {
        let (t, service) = try setUp(settings: #"{"apiKeyHelper":"x"}"#)
        try installToken(t)
        refuses(service, t, label: "pool-a", code: .keyInSettings)
        _ = try service.prepareRun(label: "main", arguments: [])
    }

    @Test func theVerdictHoldsNoEnvNameNoValueAndNoCommand() throws {
        let canary = Canaries.apiKey()
        let body =
            "{\"env\":{\"ANTHROPIC_API_KEY\":\"\(canary)\"},\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo secret-cmd\"}]}]}}"
        let (t, _) = try setUp(settings: body)
        let seen = try String(
            contentsOf: t.context.dataRoot.appendingPathComponent("state/settings-seen.json"),
            encoding: .utf8)
        #expect(
            !seen.contains(canary) && !seen.contains("ANTHROPIC") && !seen.contains("secret-cmd"))
        #expect(seen.contains("\"carriesKey\":true"))
    }

    @Test func pickAndTheOtherReadersEachSaveTheVerdict() throws {
        let (t, _) = try setUp(settings: hookBody)
        let seen = t.context.dataRoot.appendingPathComponent("state/settings-seen.json")
        try FileManager.default.removeItem(at: seen)
        _ = try PickService(context: t.context).pick(PickRequest(dryRun: true))
        #expect(FileManager.default.fileExists(atPath: seen.path))
    }

    // MARK: D2, argument order and refusals

    @Test func theSettingsPairComesFirstInTheArgvAndTheLine() throws {
        let (t, service) = try setUp(settings: hookBody)
        for arguments in [
            ["-c"], ["foo", "--", "bar"], ["--model"], ["x", "mcp", "list"], ["--", "-p"],
            ["-notacommand"],
        ] {
            let launch = try service.prepareRun(label: "main", arguments: arguments)
            #expect(launch.arguments.first == "--settings")
            #expect(Array(launch.arguments.dropFirst(2)) == arguments)
            #expect(launch.arguments.filter { $0 == "--settings" }.count == 1)
            #expect(
                launch.line
                    == (["claude", try Recipe.launchArgs(settingsPath: launch.arguments[1])]
                    + arguments.map(PickService.shellQuote)).joined(separator: " "))
        }
        #expect(!startedClaude(t))
    }

    @Test func aSettingsFormInThePersonsArgumentsIsRefusedBeforeAnyWrite() throws {
        let (t, service) = try setUp(settings: hookBody)
        for arguments in [
            ["--settings", "x"], ["--settings=x"], ["-c", "--settings", "x"],
            ["a", "--settings={}"],
        ] {
            refuses(service, t, arguments: arguments)
            refuses(service, t, arguments: arguments, printOnly: true)
        }
    }

    @Test func aFirstArgumentThatIsAClaudeSubcommandIsRefusedBeforeAnyWrite() throws {
        let (t, service) = try setUp(settings: hookBody)
        for name in ClaudeSubcommands.names.sorted() {
            refuses(service, t, arguments: [name])
            refuses(service, t, arguments: [name, "x"], printOnly: true)
        }
        // Later arguments and other first arguments are never refused for their words.
        _ = try service.prepareRun(label: "main", arguments: ["--name", "list"])
        _ = try service.prepareRun(label: "main", arguments: ["-p", "mcp"])
        _ = try service.prepareRun(label: "main", arguments: ["mcp list now"])
        _ = try service.prepareRun(label: "main", arguments: ["-mcp"])
    }

    @Test func theChatShellLineAndTheRunPathRefuseTheSameArguments() throws {
        let (t, service) = try setUp(settings: hookBody)
        let before = tree(t)
        for arguments in [["--settings", "x"], ["auth", "logout"], ["--settings=x"]] {
            #expect(throws: ToolError.self) {
                try service.chatShellLine(label: "main", arguments: arguments)
            }
        }
        #expect(tree(t) == before)
    }

    // MARK: D3, the chat shell line

    @Test func theChatShellLineIsTheCommandToTypeAndWritesNothing() throws {
        let (t, service) = try setUp(settings: hookBody)
        try installToken(t)
        let before = tree(t)
        #expect(
            try service.chatShellLine(label: "main", arguments: []) == "agent-balancer run main")
        #expect(
            try service.chatShellLine(label: "pool-a", arguments: ["-c", "it's", "$(id)", "a\nb"])
                == "agent-balancer run pool-a -- -c 'it'\\''s' '$(id)' $'a\\nb'")
        #expect(tree(t) == before)
        #expect(!startedClaude(t))
        #expect(throws: ToolError.self) { try service.chatShellLine(label: "nope", arguments: []) }
        #expect(throws: ToolError.self) {
            try service.chatShellLine(label: "main; id", arguments: [])
        }
    }

    @Test func aTokenShapedArgumentIsNotEchoedInAnyPrintedLine() throws {
        let (t, service) = try setUp(settings: hookBody)
        let secret = Canaries.oauthRealShape()
        let before = tree(t)
        #expect(throws: ToolError.self) {
            try service.chatShellLine(label: "main", arguments: ["--x", secret])
        }
        refuses(service, t, arguments: [secret], printOnly: true)
        #expect(tree(t) == before)
    }

    @Test func controlCharactersInAnArgumentArePrintedAsEscapes() {
        #expect(PickService.shellQuote("a\u{1b}[31m") == "$'a\\x1b[31m'")
        #expect(PickService.shellQuote("tab\there") == "$'tab\\there'")
        #expect(PickService.shellQuote("plain-1.2") == "plain-1.2")
        #expect(PickService.shellQuote("a b") == "'a b'")
    }

    // MARK: D4, a printed line is a typing caller

    @Test func printOnlyRefusesUnderAnAmbientConfigFolderAndWritesNothing() throws {
        let (t, service) = try setUp(
            settings: hookBody, ambient: ["CLAUDE_CONFIG_DIR": "/tmp/elsewhere"])
        try installToken(t)
        refuses(service, t, printOnly: true)
        refuses(service, t, label: "pool-a", printOnly: true)
        // Starting a session drops the variable from the child, so run itself still goes ahead.
        _ = try service.prepareRun(label: "main", arguments: [])
    }

    @Test func printOnlyRefusesUnderAnInheritedTokenOrKeyAndWritesNothing() throws {
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", ProtectedEnv.tokenVariable] {
            let (t, service) = try setUp(settings: hookBody, ambient: [name: "x"])
            try installToken(t)
            refuses(service, t, printOnly: true)
            refuses(service, t, label: "pool-a", printOnly: true)
            _ = try service.prepareRun(label: "pool-a", arguments: [])
        }
    }

    @Test func printOnlyAndATypedPickUseTheSameAmbientPredicate() throws {
        let cases: [([String: String], Bool, Bool)] = [
            (["CLAUDE_CONFIG_DIR": "/x"], true, false), (["CLAUDE_CONFIG_DIR": ""], true, false),
            (["ANTHROPIC_API_KEY": "x"], false, true), ([:], false, false),
        ]
        for (ambient, configDir, key) in cases {
            let state = PickService.AmbientState(ambient)
            #expect(state.configDir == configDir && state.key == key)
            let (t, service) = try setUp(settings: hookBody, ambient: ambient)
            // A typed pick skips the default-folder kinds under a config folder and marks the
            // answer background only under a key; a printed run refuses for either.
            let picked = try service.pick(PickRequest(dryRun: true))
            let skipped = picked.candidates.contains {
                $0.label == "main" && $0.reason.contains("ambient CLAUDE_CONFIG_DIR")
            }
            #expect(skipped == configDir)
            if picked.label != nil { #expect(picked.backgroundOnly == key) }
            if configDir || key {
                refuses(service, t, printOnly: true)
            } else {
                _ = try service.prepareRun(label: "main", arguments: [], printOnly: true)
            }
        }
    }

    // MARK: Minors

    @Test func aSaveRefusesWhenTheLinkListCannotBeDecoded() throws {
        let t = try TestHome()
        let hooks = HookRecord(context: t.context)
        let file = t.context.dataRoot.appendingPathComponent("links.json")
        try FileManager.default.createDirectory(
            at: t.context.dataRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let broken = "{\"schemaVersion\":1,\"links\":\"oops\"}"
        try broken.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: ToolError.self) { try hooks.record(.empty) }
        #expect(try String(contentsOf: file, encoding: .utf8) == broken)
        // A record that is only missing its hook part keeps its links on the next save.
        let kept =
            "{\"schemaVersion\":1,\"links\":[{\"path\":\"p\",\"target\":\"t\"}]}"
        try kept.write(to: file, atomically: true, encoding: .utf8)
        try hooks.record(.empty)
        #expect(hooks.listedLinks() == [LinkEntry(path: "p", target: "t")])
    }

    @Test func abandoningARunDropsItsLaunchFileAndLease() throws {
        let (t, service) = try setUp(settings: hookBody)
        try installToken(t)
        let launch = try service.prepareRun(label: "pool-a", arguments: [])
        #expect(TokenAccounts.openLeaseCount(context: t.context, leaseMinutes: 30) == 1)
        service.abandon(launch)
        #expect(TokenAccounts.openLeaseCount(context: t.context, leaseMinutes: 30) == 0)
        #expect(!FileManager.default.fileExists(atPath: launch.arguments[1]))
    }

    @Test func runLooksForClaudeBeforeItWritesAnything() throws {
        let (t, service) = try setUp(settings: hookBody, accounts: [token()])
        try installToken(t)
        try FileManager.default.removeItem(at: t.fakePath)
        refuses(service, t, label: "pool-a")
    }
}
