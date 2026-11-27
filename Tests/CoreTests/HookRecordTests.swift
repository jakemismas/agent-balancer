import Foundation
import Testing

@testable import Core

@Suite struct HookRecordTests {
    func settings(_ t: TestHome, _ json: String) throws {
        let dir = t.context.defaultClaudeFolder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(
            to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    func hook(_ event: String, _ matcher: String, _ command: String) -> String {
        "\"\(event)\":[{\"matcher\":\"\(matcher)\",\"hooks\":[{\"type\":\"command\",\"command\":\"\(command)\"}]}]"
    }

    @Test func parsesHookEntriesAndHashesTheCommand() throws {
        let command = "/bin/secret-script " + Canaries.tail()
        let json = "{\"hooks\":{\(hook("PreToolUse", "Bash", command))}}"
        let facts = try HookRecord.parse(Data(json.utf8))
        #expect(facts.hooks.count == 1)
        #expect(facts.hooks[0].event == "PreToolUse" && facts.hooks[0].matcher == "Bash")
        #expect(facts.hooks[0].commandHash.count == 64)
        #expect(!String(describing: facts).contains(command))
    }

    @Test func takesNoOtherValueFromTheFile() throws {
        let canary = Canaries.oauth()
        let json = """
            {"model":"\(canary)","permissions":{"allow":["\(canary)"]},"statusLine":{"command":"\(canary)"},
             "env":{"OTHER":"\(canary)","ANTHROPIC_API_KEY":"\(canary)"},"apiKeyHelper":"\(canary)",
             "disableAllHooks":true}
            """
        let facts = try HookRecord.parse(Data(json.utf8))
        #expect(facts.disableAllHooks)
        #expect(facts.apiKeyHelperPresent)
        #expect(facts.keyEnvNames == ["ANTHROPIC_API_KEY"])
        #expect(!String(describing: facts).contains(canary))
    }

    @Test func detectsEachKeyNameByNameOnly() throws {
        let names = [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", ProtectedEnv.tokenVariable,
            "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_USE_FOUNDRY",
            "CLAUDE_CODE_GATEWAY_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
            "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR", "ANTHROPIC_PROFILE", "ANTHROPIC_CONFIG_DIR",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_SESSION_INGRESS_TOKEN_FILE",
            "CLAUDE_BRIDGE_OAUTH_TOKEN", "USE_LOCAL_OAUTH", ProtectedEnv.configDirVariable,
        ]
        for name in names {
            let json = "{\"env\":{\"\(name)\":\"v\"}}"
            let facts = try HookRecord.parse(Data(json.utf8))
            #expect(facts.keyEnvNames == [name], "\(name)")
            #expect(facts.carriesKey, "\(name)")
            #expect(!facts.hooksOff, "\(name)")
        }
        #expect(try HookRecord.parse(Data("{\"env\":{\"PATH\":\"v\"}}".utf8)).carriesKey == false)
    }

    @Test func aHarmlessNameInEnvIsNoKeyAndSwitchesNoHooksOff() throws {
        for name in [
            "CLAUDE_CODE_SUBAGENT_MODEL", "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS", "CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS",
            "CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT", "CLAUDE_BG_AUTO_MEMORY_OFF",
            "CLAUDE_CODE_RESUME_SESSIONSTART_HOOKS_WAIT_MS", "CLAUDE_CODE_HOOKS_SAME_THREAD",
            "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS", "CLAUDE_CODE_FLEETVIEW_SIMPLE",
        ] {
            let facts = try HookRecord.parse(Data("{\"env\":{\"\(name)\":\"v\"}}".utf8))
            #expect(!facts.carriesKey, "\(name)")
            #expect(!facts.hooksOff, "\(name)")
            #expect(facts.keyEnvNames.isEmpty && facts.hooksOffEnvNames.isEmpty, "\(name)")
        }
    }

    @Test func anEnvNameThatSwitchesHooksOffOrLoadsAnotherSourceReadsAsHooksOff() throws {
        for name in ProtectedEnv.behaviorNames + ProtectedEnv.settingsSourceNames {
            let facts = try HookRecord.parse(Data("{\"env\":{\"\(name)\":\"1\"}}".utf8))
            #expect(facts.hooksOffEnvNames == [name], "\(name)")
            #expect(facts.hooksOff && !facts.disableAllHooks, "\(name)")
        }
        let t = try TestHome()
        let record = HookRecord(context: t.context)
        try record.record(.empty)
        try settings(t, "{\"env\":{\"CLAUDE_CODE_MANAGED_SETTINGS_PATH\":\"/x\"}}")
        guard case .changed = record.status(current: try record.readSettings()) else {
            Issue.record("a settings source in env must read as hooks off")
            return
        }
    }

    /// The settings scan and a typed line judge every name by the one predicate.
    @Test func theSettingsScanAndATypedLineJudgeEveryNameAlike() throws {
        let names =
            ProtectedEnv.behaviorNames + ProtectedEnv.settingsSourceNames
            + ChildEnvironmentTests.namesThatLeaveHooksOn + [
                "CLAUDE_CODE_DISABLE_PERMISSION_PROMPT_NOTIFY_HOOKS", "CLAUDE_CODE_NEW_HOOKS_X",
                "CLAUDE_CODE_NEW_NAME_X", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SUBAGENT_MODEL",
            ]
        for name in names {
            let facts = try HookRecord.parse(Data("{\"env\":{\"\(name)\":\"1\"}}".utf8))
            let typed = PickService.AmbientState([name: "1"]).hooksOffName != nil
            #expect(facts.hooksOffEnvNames == (ProtectedEnv.mayDisableHooks(name) ? [name] : []))
            #expect(facts.hooksOff == typed, "\(name)")
        }
        let worded = try HookRecord.parse(
            Data(#"{"env":{"CLAUDE_CODE_NEW_HOOKS_X":"1"}}"#.utf8))
        #expect(worded.hooksOffEnvNames == ["CLAUDE_CODE_NEW_HOOKS_X"])
    }

    @Test func signInKeysOtherThanTheKeyHelperAreNeverRead() throws {
        for key in [
            "forceLoginMethod", "forceLoginOrgUUID", "awsAuthRefresh", "awsCredentialExport",
            "gcpAuthRefresh",
        ] {
            let facts = try HookRecord.parse(Data("{\"\(key)\":\"v\"}".utf8))
            #expect(facts == .empty, "\(key)")
        }
        #expect(try HookRecord.parse(Data("{\"apiKeyHelper\":\"v\"}".utf8)).carriesKey)
    }

    @Test func rejectsANonObject() {
        #expect(throws: (any Error).self) { try HookRecord.parse(Data("[1]".utf8)) }
        #expect(throws: (any Error).self) { try HookRecord.parse(Data("nope".utf8)) }
    }

    @Test func noSettingsFileIsAnEmptySetAndInitStyleRecordIsEmpty() throws {
        let t = try TestHome()
        let record = HookRecord(context: t.context)
        let facts = try record.readSettings()
        #expect(facts == .empty)
        #expect(record.status(current: facts) == .missing)
        try record.record(facts)
        #expect(record.status(current: facts) == .matches(added: 0))
    }

    @Test func removalChangesAndAdditionPasses() throws {
        let t = try TestHome()
        try settings(t, "{\"hooks\":{\(hook("PreToolUse", "Bash", "a")),\(hook("Stop", "", "b"))}}")
        let record = HookRecord(context: t.context)
        try record.record(try record.readSettings())

        try settings(
            t,
            "{\"hooks\":{\(hook("PreToolUse", "Bash", "a")),\(hook("Stop", "", "b")),\(hook("PostToolUse", "", "c"))}}"
        )
        #expect(record.status(current: try record.readSettings()) == .matches(added: 1))

        try settings(t, "{\"hooks\":{\(hook("PreToolUse", "Bash", "a"))}}")
        guard case .changed(let diff) = record.status(current: try record.readSettings()) else {
            Issue.record("expected changed")
            return
        }
        #expect(diff.removed.count == 1 && diff.removed[0].event == "Stop")

        try settings(
            t, "{\"hooks\":{\(hook("PreToolUse", "Bash", "changed")),\(hook("Stop", "", "b"))}}")
        guard case .changed(let edited) = record.status(current: try record.readSettings()) else {
            Issue.record("expected changed")
            return
        }
        #expect(edited.removed.count == 1 && edited.added.count == 1)
    }

    @Test func disableAllHooksChangesTheStatus() throws {
        let t = try TestHome()
        let record = HookRecord(context: t.context)
        try record.record(.empty)
        try settings(t, "{\"disableAllHooks\":true}")
        guard case .changed = record.status(current: try record.readSettings()) else {
            Issue.record("expected changed")
            return
        }
    }

    @Test func aDamagedRecordIsMissing() throws {
        let t = try TestHome()
        try NoFollowWriter(root: t.context.dataRoot).put(
            Data("{not json".utf8), folders: [], name: "links.json")
        #expect(HookRecord(context: t.context).status(current: .empty) == .missing)
    }

    @Test func recordHoldsHashesAndNoCommandText() throws {
        let t = try TestHome()
        let command = "/opt/tools/run-" + Canaries.tail(12)
        try settings(t, "{\"hooks\":{\(hook("Stop", "", command))}}")
        let record = HookRecord(context: t.context)
        try record.record(try record.readSettings())
        let text = try String(
            contentsOf: t.context.dataRoot.appendingPathComponent("links.json"), encoding: .utf8)
        #expect(!text.contains(command) && !text.contains("run-"))
        #expect(text.contains("commandHash"))
    }
}

@Suite struct HookFingerprintTests {
    func facts(_ hooks: String) throws -> SettingsFacts {
        try HookRecord.parse(Data("{\"hooks\":{\"Stop\":[{\"hooks\":[\(hooks)]}]}}".utf8))
    }

    @Test func nonCommandHooksAreFingerprinted() throws {
        let a = try facts("{\"type\":\"http\",\"url\":\"https://a.example\"}")
        let b = try facts("{\"type\":\"http\",\"url\":\"https://b.example\"}")
        #expect(a.hooks.count == 1 && b.hooks.count == 1)
        #expect(a.hooks[0].fingerprint != b.hooks[0].fingerprint)
    }

    @Test func otherFieldsChangeTheFingerprint() throws {
        let a = try facts("{\"type\":\"command\",\"command\":\"x\",\"timeout\":5}")
        let b = try facts("{\"type\":\"command\",\"command\":\"x\",\"timeout\":9}")
        #expect(a.hooks[0].commandHash == b.hooks[0].commandHash)
        #expect(a.hooks[0].fingerprint != b.hooks[0].fingerprint)
    }

    @Test func keyOrderDoesNotChangeTheFingerprint() throws {
        let a = try facts("{\"type\":\"command\",\"command\":\"x\"}")
        let b = try facts("{\"command\":\"x\",\"type\":\"command\"}")
        #expect(a.hooks == b.hooks)
    }

    @Test func unrecognisedShapesThrow() {
        let bad = [
            "{\"hooks\":[1]}", "{\"hooks\":{\"Stop\":{}}}", "{\"hooks\":{\"Stop\":[1]}}",
            "{\"hooks\":{\"Stop\":[{\"hooks\":{}}]}}", "{\"hooks\":{\"Stop\":[{}]}}",
            "{\"hooks\":{\"Stop\":[{\"hooks\":[\"x\"]}]}}",
            "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":5}]}]}}",
            "{\"hooks\":{\"Stop\":[{\"matcher\":1,\"hooks\":[]}]}}",
        ]
        for json in bad {
            #expect(throws: (any Error).self) { try HookRecord.parse(Data(json.utf8)) }
        }
    }

    @Test func displayEscapesControlCharacters() {
        let text = Display.safe("a\nb\u{1b}[2Jc\u{85}")
        #expect(
            !text.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x1b || $0.value == 0x85
            })
        #expect(Display.safe(String(repeating: "x", count: 500)).count < 130)
        let entry = HookEntry(
            event: "E\n+ forged", matcher: "m\u{1b}[H", commandHash: "", fingerprint: "ab")
        #expect(!entry.summary.contains("\n") && !entry.summary.contains("\u{1b}"))
    }
}
