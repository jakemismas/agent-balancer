import Foundation
import Testing

@testable import Core

@Suite struct ConfigTests {
    func config(_ accounts: [Account] = []) -> Config { Config(accounts: accounts) }

    func login(_ label: String = "main") -> Account {
        Account(label: label, kind: Kind.login, role: Role.pool, email: "main@example.com")
    }

    func message(_ c: Config) -> String? {
        do {
            try ConfigValidator.validate(c)
            return nil
        } catch let e as ToolError { return e.message } catch { return "other" }
    }

    @Test func acceptsAValidConfig() {
        #expect(message(config([login()])) == nil)
    }

    @Test(arguments: ["", "Main", "-a", "a b", "a_b", String(repeating: "a", count: 33), "../x"])
    func rejectsBadLabels(label: String) {
        #expect(message(config([login(label)]))?.contains("not valid") == true)
    }

    @Test func rejectsASecondLoginAccount() {
        #expect(message(config([login("a"), login("b")]))?.contains("one login") == true)
    }

    @Test func acceptsTheFolderKindAndRejectsUnknownKindAndRole() {
        let folder = Account(label: "f", kind: Kind.folder, role: Role.pool)
        #expect(message(config([folder])) == nil)
        let odd = Account(label: "o", kind: "weird", role: Role.pool)
        #expect(message(config([odd]))?.contains("unknown kind") == true)
        let role = Account(label: "o", kind: Kind.token, role: "boss")
        #expect(message(config([role]))?.contains("unknown role") == true)
    }

    @Test func rejectsDuplicateLabels() {
        let a = Account(label: "x", kind: Kind.token, role: Role.pool)
        #expect(message(config([a, a]))?.contains("twice") == true)
    }

    @Test func rejectsReservePointsAbove90OnMainWithoutTheFlag() {
        let high = Reserve(
            points: [ReservePoint(daysLeft: 2, maxUsedPercent: 95)], marginPercent: 5)
        let main = Account(label: "m", kind: Kind.login, role: Role.main, reserve: high)
        #expect(message(config([main]))?.contains("90 percent") == true)
        var allowed = high
        allowed.allowAbove90 = true
        let ok = Account(label: "m", kind: Kind.login, role: Role.main, reserve: allowed)
        #expect(message(config([ok])) == nil)
    }

    @Test func rejectsUnknownSchemaVersions() {
        #expect(message(Config(schemaVersion: 2))?.contains("schemaVersion 2") == true)
    }

    @Test func storeRoundTripsAndHoldsNoExecutablePath() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        #expect(try store.load() == nil)
        var c = config([login()])
        c.probe.safeMode = true
        try store.save(c)
        #expect(try store.load() == c)
        let text = try String(
            contentsOf: t.home.appendingPathComponent(".agent-balancer/config.json"),
            encoding: .utf8)
        #expect(!text.contains("configDir") && !text.contains("claudePath"))
        #expect(text.contains("\"schemaVersion\" : 1"))
    }

    @Test func saveKeepsKeysThisVersionDoesNotKnow() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        let json = """
            {"schemaVersion":1,"picker":{"a":1},"probe":{"safeMode":false,"timeoutSeconds":60,"passProxyEnv":false,"extra":2},\
            "accounts":[{"label":"x","kind":"token","role":"pool","accountKey":"k1",\
            "futureKey":true,"endsAt":"2026-12-31"}]}
            """
        try NoFollowWriter(root: t.context.dataRoot).put(
            Data(json.utf8), folders: [], name: "config.json")
        var c = try store.loadRequired()
        c.accounts[0].endsAt = nil
        try store.save(c, backup: true)
        let raw = try Data(contentsOf: t.home.appendingPathComponent(".agent-balancer/config.json"))
        let o = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(o["picker"] != nil)
        #expect((o["probe"] as? [String: Any])?["extra"] as? Int == 2)
        let a = try #require((o["accounts"] as? [[String: Any]])?.first)
        #expect(a["futureKey"] as? Bool == true)
        #expect(a["endsAt"] == nil)
    }

    @Test func validatorEscapesControlCharactersInLabels() {
        let m = message(config([login("a\u{1b}[2Jb")])) ?? ""
        #expect(!m.contains("\u{1b}"))
    }

    @Test func storeRefusesAnUnknownSchemaOnDisk() throws {
        let t = try TestHome()
        try NoFollowWriter(root: t.context.dataRoot).put(
            Data("{\"schemaVersion\":9,\"accounts\":[]}".utf8), folders: [], name: "config.json")
        #expect(throws: ToolError.self) { try ConfigStore(context: t.context).load() }
    }

    @Test func backupGoesToBackupsAndNeverOverwritesAnEarlierOne() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        try store.save(config([login()]))
        var c = try store.loadRequired()
        c.refresh.backgroundMinutes = 30
        try store.save(c, backup: true)
        c.refresh.backgroundMinutes = 45
        try store.save(c, backup: true)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: t.home.appendingPathComponent(".agent-balancer/backups").path)
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.hasPrefix("config-") })
    }

    @Test func aSymlinkedBackupsFolderIsRefusedAndNothingIsWrittenThroughIt() throws {
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        try store.save(config([login()]))
        let outside = t.home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: t.home.appendingPathComponent(".agent-balancer/backups"),
            withDestinationURL: outside)
        var c = try store.loadRequired()
        c.refresh.backgroundMinutes = 5
        #expect(throws: ToolError.self) { try store.save(c, backup: true) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try store.loadRequired().refresh.backgroundMinutes == 60)
    }

    @Test func pickerAndLaunchKeysDefaultAndRoundTrip() throws {
        let d = Config()
        #expect(d.picker.limitedAtPercent == 95 && d.picker.minRoomPercent == 5)
        #expect(d.picker.deadlineSeconds == 45 && d.picker.leaseMinutes == 10)
        #expect(d.picker.expectedRunPercent == 5 && d.picker.endingSoonAssumeDays == 2)
        #expect(d.launch.settingsKeys == ["env"] && d.launch.envNames.isEmpty)
        #expect(d.launch.keepDays == 35)
        let t = try TestHome()
        let store = ConfigStore(context: t.context)
        var c = config([login()])
        c.picker.limitedAtPercent = 90
        c.launch.envNames = ["MY_FLAG"]
        c.accounts[0].fable = AccountFable(allowLaunches: false)
        try store.save(c)
        #expect(try store.load() == c)
        let partial = "{\"schemaVersion\":1,\"picker\":{\"minRoomPercent\":7}}"
        let decoded = try JSONDecoder().decode(Config.self, from: Data(partial.utf8))
        #expect(decoded.picker.minRoomPercent == 7 && decoded.picker.limitedAtPercent == 95)
    }

    @Test func validatorChecksThePickerAndLaunchKeys() {
        func bad(_ tune: (inout Config) -> Void) -> String? {
            var c = config([login()])
            tune(&c)
            return message(c)
        }
        #expect(bad { $0.picker.limitedAtPercent = 0 }?.contains("limitedAtPercent") == true)
        #expect(bad { $0.picker.minRoomPercent = 101 }?.contains("minRoomPercent") == true)
        #expect(bad { $0.picker.deadlineSeconds = 0 }?.contains("deadlineSeconds") == true)
        #expect(bad { $0.picker.leaseMinutes = 0 }?.contains("leaseMinutes") == true)
        #expect(bad { $0.picker.expectedRunPercent = -1 }?.contains("expectedRunPercent") == true)
        #expect(
            bad { $0.picker.endingSoonAssumeDays = -1 }?.contains("endingSoonAssumeDays") == true)
        #expect(bad { $0.launch.keepDays = 0 }?.contains("keepDays") == true)
        #expect(bad { $0.launch.envNames = ["bad name"] }?.contains("envNames") == true)
        #expect(bad { $0.launch.settingsKeys = ["a b"] }?.contains("settingsKeys") == true)
        #expect(bad { _ in } == nil)
    }

    @Test func theDesignsExampleLaunchListsLoad() throws {
        let keys = #""settingsKeys":["env","crossSessionInbound"]"#
        let names = #""envNames":["CLAUDE_ROLE","CLAUDE_CLIENT"]"#
        let text = "{\"schemaVersion\":1,\"accounts\":[],\"launch\":{\(keys),\(names)}}"
        let decoded = try JSONDecoder().decode(Config.self, from: Data(text.utf8))
        #expect(decoded.launch.settingsKeys == ["env", "crossSessionInbound"])
        #expect(decoded.launch.envNames == ["CLAUDE_ROLE", "CLAUDE_CLIENT"])
        #expect(message(decoded) == nil)
    }

    @Test(arguments: [
        "hooks", "apiKeyHelper", "statusLine", "permissions", "disableAllHooks", "awsAuthRefresh",
        "forceLoginMethod", "model",
    ])
    func aSettingsKeyThatIsNotOnTheAllowlistIsRefusedAtLoad(key: String) {
        var c = config([login()])
        c.launch.settingsKeys = ["env", key]
        #expect(message(c)?.contains("settingsKeys") == true, "\(key)")
    }

    @Test(arguments: [
        "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_SHELL_PREFIX", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_JOB_DIR", "CLAUDE_PID", "CLAUDE_CONFIG_DIR", "CLAUDE_ENV_FILE",
        "ANTHROPIC_BASE_URL", "CLAUDE_BG_SESSION_CREDENTIAL", "CLAUDE_BRIDGE_BASE_URL",
        "CLAUDE_RUNNER_CLAUDE_BIN", "CCR_OAUTH_TOKEN_FILE", "USE_STAGING_OAUTH",
        "CLAUDE_LOCAL_OAUTH_API_BASE", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "BASH_ENV",
        "NODE_OPTIONS", "HTTPS_PROXY", "https_proxy", "AGENT_BALANCER_ACCOUNT", "PATH",
    ])
    func aNeverAllowedEnvNameIsRefusedAtLoad(name: String) {
        var c = config([login()])
        c.launch.envNames = [name]
        #expect(message(c)?.contains("envNames") == true, "\(name)")
    }
}
