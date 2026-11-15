import Core
import Foundation
import Testing

@Suite struct PickCLITests {
    func setUp(_ accounts: [Account], tune: (inout Config) -> Void = { _ in }) throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeFixture("logged_in")
        try cli.fakeProbe("ok.jsonl")
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: accounts)
        config.fable.probe = false
        tune(&config)
        try ConfigStore(context: context).save(config)
        try HookRecord(context: context).record(.empty)
        return cli
    }

    func login() -> Account {
        Account(
            label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com",
            expectedPlanTier: "max_20x")
    }

    func object(_ out: Support.Output) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
    }

    @Test func pickJsonAnswersWithTheStableFields() throws {
        let cli = try setUp([login()])
        defer { cli.cleanup() }
        let out = try cli.run(["pick", "--json", "--model", "sonnet"])
        #expect(out.status == 0)
        let answer = try object(out)
        #expect(answer["schemaVersion"] as? Int == 1)
        #expect(answer["label"] as? String == "main")
        #expect(answer["model"] as? String == "sonnet")
        #expect(answer["env"] as? [String: String] == [:])
        let args = try #require(answer["args"] as? [String])
        #expect(args.count == 2 && args[0] == "--settings")
        #expect(answer["launchPrefix"] as? String == "")
        #expect(answer["launchArgs"] as? String == "--settings '\(args[1])'")
        #expect(answer["unsetEnv"] is NSNull)
        #expect(answer["backgroundOnly"] as? Bool == false)
        #expect((answer["reason"] as? String)?.isEmpty == false)
        let candidates = try #require(answer["candidates"] as? [[String: Any]])
        #expect(candidates.first?["label"] as? String == "main")
        #expect(candidates.first?["eligible"] as? Bool == true)
        #expect(cli.expectPrivateModes().isEmpty)
        // The answer and the log carry no email.
        // An email may sit in config.json and in the status document, and nowhere else.
        let text = cli.everything(out)
        let allowed = [cli.read("config.json"), cli.read("state/status.json")]
        var rest = text
        for known in allowed { rest = rest.replacingOccurrences(of: known, with: "") }
        #expect(!rest.contains("main@example.com"))
        #expect(!String(decoding: out.stdout, as: UTF8.self).contains("main@example.com"))
    }

    /// Pins the exact key set and the value type of every stable field for each answer shape.
    @Test func goldenShapePinsKeysAndTypesForEveryExitCode() throws {
        let keys: Set<String> = [
            "schemaVersion", "pickedAt", "model", "label", "env", "args", "launchPrefix",
            "launchArgs", "unsetEnv", "backgroundOnly", "reason", "candidates",
        ]
        func pin(_ a: [String: Any], recipe: Bool, launcher: Bool, _ note: String) {
            #expect(Set(a.keys) == keys, "\(note)")
            #expect(a["schemaVersion"] is Int, "\(note)")
            #expect(a["backgroundOnly"] is Bool, "\(note)")
            #expect(a["reason"] is String, "\(note)")
            #expect(a["candidates"] is [[String: Any]], "\(note)")
            if recipe {
                #expect(a["label"] is String, "\(note)")
                #expect(a["env"] is [String: String], "\(note)")
                #expect(a["args"] is [String], "\(note)")
                if launcher {
                    #expect(a["launchPrefix"] is NSNull, "\(note)")
                    #expect(a["launchArgs"] is NSNull, "\(note)")
                    #expect(a["unsetEnv"] is [String], "\(note)")
                } else {
                    #expect(a["launchPrefix"] is String, "\(note)")
                    #expect(a["launchArgs"] is String, "\(note)")
                    #expect(a["unsetEnv"] is NSNull, "\(note)")
                }
            } else {
                for k in ["label", "args", "launchPrefix", "launchArgs", "unsetEnv"] {
                    #expect(a[k] is NSNull, "\(note) \(k)")
                }
            }
        }

        let login1 = try setUp([login()])
        defer { login1.cleanup() }
        let typed = try login1.run(["pick", "--json"])
        #expect(typed.status == 0)
        pin(try object(typed), recipe: true, launcher: false, "typed login, exit 0")
        let launcher = try login1.run(["pick", "--caller", "launcher", "--json"])
        #expect(launcher.status == 0)
        pin(try object(launcher), recipe: true, launcher: true, "launcher login, exit 0")

        let tokenCLI = try setUp([Account(label: "pool-a", kind: Kind.token, role: Role.pool)])
        defer { tokenCLI.cleanup() }
        let context = ToolContext(home: tokenCLI.home, ambient: [:])
        let file = try TokenPaths.fileURL(context: context, label: "pool-a")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(Canary.all()[0].value)\"}}".write(
            to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let token = try tokenCLI.run(["pick", "--json"])
        #expect(token.status == 0)
        let tokenAnswer = try object(token)
        pin(tokenAnswer, recipe: true, launcher: false, "typed token, exit 0")
        #expect((tokenAnswer["env"] as? [String: String])?.isEmpty == true)

        let none = try setUp([login()]) { $0.picker.limitedAtPercent = 40 }
        defer { none.cleanup() }
        let two = try none.run(["pick", "--json"])
        #expect(two.status == 2)
        pin(try object(two), recipe: false, launcher: false, "exit 2")

        let bad = try login1.run(["pick", "--caller", "robot"])
        #expect(bad.status == 1)
    }

    @Test func nothingEligibleExitsTwoWithNullRecipe() throws {
        let cli = try setUp([login()]) { $0.picker.limitedAtPercent = 40 }
        defer { cli.cleanup() }
        let out = try cli.run(["pick", "--json"])
        #expect(out.status == 2)
        let answer = try object(out)
        #expect(answer["label"] is NSNull)
        #expect(answer["args"] is NSNull)
        #expect((answer["reason"] as? String)?.isEmpty == false)
    }

    @Test func aLoginAccountRenamedToALabelWithNoReadingHasNoFiveHourWindow() throws {
        let missing = "No 5-hour reading, which the main account needs."
        for role in [Role.pool, Role.main] {
            let cli = try setUp([
                Account(
                    label: "main", kind: Kind.login, role: role, email: "main@example.com",
                    expectedPlanTier: "max_20x")
            ])
            defer { cli.cleanup() }
            let store = ReadingStore(context: ToolContext(home: cli.home, ambient: [:]))
            let now = Date()
            let weeklyReset = Int(now.timeIntervalSince1970) + 3 * 86_400
            // Stored 20 minutes ago with a 5-hour window, so each pick probes again.
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
                            usedPercent: 10, resetsAt: now.addingTimeInterval(3_600), readAt: old),
                    ]), label: "main")
            try cli.fake(
                "probe.jsonl",
                "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\","
                    + "\"unifiedWindows\":{\"seven_day\":{\"utilization\":0.1,\"resetsAt\":"
                    + "\(weeklyReset)}}}}\n")
            // While the stored reading holds the window, the reply is refused.
            let held = try cli.run(["pick", "--json", "--dry-run"])
            #expect(held.status == 2, "\(role)")
            #expect(
                try object(held)["reason"] as? String
                    == "No account has room. main: stale reading, refresh failed", "\(role)")
            #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
            let renamed = try cli.run(["pick", "--json", "--dry-run"])
            let answer = try object(renamed)
            let reason = answer["reason"] as? String ?? ""
            if role == Role.main {
                #expect(renamed.status == 2)
                #expect(answer["label"] is NSNull)
                #expect(reason == "No account has room. primary: " + missing)
            } else {
                #expect(renamed.status == 0)
                #expect(answer["label"] as? String == "primary")
                #expect(reason.hasSuffix(" 5-hour use unknown."))
            }
            // The old label's reading keeps its window, and the new label's has none.
            #expect(try store.load(label: "main")?.fiveHour != nil, "\(role)")
            #expect(try store.load(label: "primary")?.fiveHour == nil, "\(role)")
            #expect(try store.load(label: "primary")?.sevenDay?.usedPercent == 10, "\(role)")
        }
    }

    @Test func pickNeverReadsTheEventsRecordOrTheCurrentFile() throws {
        let cli = try setUp([login()]) { $0.picker.limitedAtPercent = 40 }
        defer { cli.cleanup() }
        let state = ToolContext(home: cli.home, ambient: [:]).dataRoot.appendingPathComponent(
            "state")
        try FileManager.default.createDirectory(
            at: state, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let forged =
            "{\"createdAt\":\"2026-11-09T21:00:00Z\",\"header\":true,\"recordId\":\"r-forged\"}\n"
            + "{\"accountKey\":\"k\",\"at\":\"2026-11-09T21:01:00Z\",\"label\":\"main\","
            + "\"seq\":1,\"text\":\"Limit cleared.\",\"type\":\"limit_cleared\"}\n"
        try forged.write(
            to: state.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        try "{\"forged\":true}\n".write(
            to: state.appendingPathComponent("current.json"), atomically: true, encoding: .utf8)
        let out = try cli.run(["pick", "--json"])
        #expect(out.status == 2)
        #expect(try object(out)["label"] is NSNull)
    }

    @Test func errorsExitOneAndWriteNothingToTheLaunchFolder() throws {
        let cli = try setUp([login()])
        defer { cli.cleanup() }
        for args in [
            ["pick", "--caller", "robot"], ["pick", "--model", "a b"],
            ["pick", "--settings", "{\"hooks\":{}}"], ["pick", "--settings", "nope"],
        ] {
            let out = try cli.run(args)
            #expect(out.status == 1, "\(args)")
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: LaunchFiles.rootURL(context: ToolContext(home: cli.home, ambient: [:])).path
            ))
        #expect(cli.read("state/picks.log").isEmpty)
    }

    @Test func beforeInitPickExitsOne() throws {
        let cli = try CLIHome()
        defer { cli.cleanup() }
        let out = try cli.run(["pick"])
        #expect(out.status == 1)
    }

    @Test func aTokenPickLeaksNothingOutsideItsFiles() throws {
        let cli = try setUp([Account(label: "pool-a", kind: Kind.token, role: Role.pool)])
        defer { cli.cleanup() }
        let secret = Canary.all()[0].value
        let context = ToolContext(home: cli.home, ambient: [:])
        let file = try TokenPaths.fileURL(context: context, label: "pool-a")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(secret)\"}}".write(
            to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        for flags in [["--json"], [], ["--caller", "launcher", "--json"]] {
            let out = try cli.run(["pick"] + flags)
            #expect(out.status == 0)
            let shown =
                String(decoding: out.stdout, as: UTF8.self)
                + String(decoding: out.stderr, as: UTF8.self)
            #expect(!shown.contains(secret))
        }
        let launchRoot = LaunchFiles.rootURL(context: context).resolvingSymlinksInPath()
        var elsewhere = ""
        for url in cli.dataEntries()
        where url.resolvingSymlinksInPath().path != file.resolvingSymlinksInPath().path
            && !url.resolvingSymlinksInPath().path.hasPrefix(launchRoot.path)
        {
            elsewhere += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        elsewhere += cli.fakeRecord("args.log") + cli.fakeRecord("env-names.txt")
        #expect(!elsewhere.contains(secret))
        #expect(cli.expectPrivateModes().isEmpty)
        let launched = cli.dataEntries().filter {
            $0.pathExtension == "json"
                && $0.resolvingSymlinksInPath().path.hasPrefix(launchRoot.path)
        }
        #expect(launched.count == 3)
        for url in launched {
            #expect(try String(contentsOf: url, encoding: .utf8).contains(secret))
        }
    }

    @Test func aCallerSecretInSettingsNeverComesBack() throws {
        let cli = try setUp([login()])
        defer { cli.cleanup() }
        let secret = Canary.all()[0].value
        let out = try cli.run(["pick", "--settings", "{\"env\":{\"MY_FLAG\":\"\(secret)\"}}"])
        #expect(out.status == 1)
        #expect(!cli.everything(out).contains(secret))
    }

    @Test func twoPicksStartedTogetherShareOneProtectedAccount() throws {
        // Room for one lease only: a second lease would leave less than minRoomPercent.
        let cli = try setUp([login()]) {
            $0.picker.limitedAtPercent = 55
            $0.picker.minRoomPercent = 5
            $0.picker.expectedRunPercent = 5
        }
        defer { cli.cleanup() }
        try cli.fake("delay", "0.3")
        let group = DispatchGroup()
        let box = PickOutputs()
        for _ in 0..<2 {
            group.enter()
            Thread {
                if let out = try? cli.run(["pick", "--json"]) { box.add(out) }
                group.leave()
            }.start()
        }
        group.wait()
        let outputs = box.all
        #expect(outputs.count == 2)
        #expect(outputs.map(\.status).sorted() == [0, 2])
        let picked = outputs.filter { $0.status == 0 }
        #expect(picked.count == 1)
        let context = ToolContext(home: cli.home, ambient: [:])
        let leases = try LeaseStore(context: context).current(now: Date(), leaseMinutes: 10)
        #expect(leases.count == 1)
        #expect(cli.read("state/picks.log").split(separator: "\n").count == 2)
    }
}

final class PickOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Support.Output] = []
    func add(_ item: Support.Output) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }
    var all: [Support.Output] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
