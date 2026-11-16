import Core
import Foundation
import Testing

@Suite struct RefreshCLITests {
    func setUp(_ accounts: [Account], probe: String = "ok.jsonl") throws -> CLIHome {
        let cli = try CLIHome()
        try cli.fakeProbe(probe)
        let context = ToolContext(home: cli.home, ambient: [:])
        var config = Config(accounts: accounts)
        config.fable.probe = false
        try ConfigStore(context: context).save(config)
        return cli
    }

    func login() -> Account {
        Account(label: "main", kind: Kind.login, role: Role.pool, email: "main@example.com")
    }

    @Test func refreshStoresAReadingAndPrintsOnlyNumbers() throws {
        let cli = try setUp([login()])
        defer { cli.cleanup() }
        let out = try cli.run(["refresh"])
        #expect(out.status == 0)
        let text = String(decoding: out.stdout, as: UTF8.self)
        #expect(text.contains("main: read (5 hour 12.3%, week 45.6%)"))
        #expect(cli.read("state/readings/main.json").contains("\"usedPercent\" : 45.6"))
        #expect(cli.expectPrivateModes().isEmpty)
        #expect(
            !cli.everything(out).contains("example.com")
                || cli.read("config.json").contains("example.com"))
        let second = try cli.run(["refresh"])
        #expect(String(decoding: second.stdout, as: UTF8.self).contains("main: fresh"))
        let forced = try cli.run(["refresh", "--force", "--label", "main"])
        #expect(String(decoding: forced.stdout, as: UTF8.self).contains("main: read"))
    }

    @Test func aTokenAccountLeaksNothingAnywhere() throws {
        let label = "pool-a"
        let cli = try setUp([Account(label: label, kind: Kind.token, role: Role.pool)])
        defer { cli.cleanup() }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let tail = String((0..<40).map { _ in alphabet.randomElement()! })
        let secret = "sk-" + "ant-" + "oat01-" + tail
        let context = ToolContext(home: cli.home, ambient: [:])
        let file = try TokenPaths.fileURL(context: context, label: label)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let body = "{\"env\":{\"\(ProtectedEnv.tokenVariable)\":\"\(secret)\"}}"
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let out = try cli.run(["refresh"])
        #expect(out.status == 0)
        var everything =
            String(decoding: out.stdout, as: UTF8.self)
            + String(decoding: out.stderr, as: UTF8.self)
        for url in cli.dataEntries()
        where url.resolvingSymlinksInPath().path != file.resolvingSymlinksInPath().path {
            everything += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        everything += cli.fakeRecord("args.log") + cli.fakeRecord("env-names.txt")
        #expect(!everything.contains(secret))
        #expect(cli.fakeRecord("args.log").contains("--settings " + file.path))
        #expect(!cli.fakeRecord("env-names.txt").contains(ProtectedEnv.tokenVariable))
        #expect(cli.expectPrivateModes().isEmpty)
    }

    @Test func aFailedProbeExitsOneAndStoresNothing() throws {
        let cli = try setUp([login()], probe: "auth_error.jsonl")
        defer { cli.cleanup() }
        let out = try cli.run(["refresh"])
        #expect(out.status == 1)
        #expect(String(decoding: out.stdout, as: UTF8.self).contains("login_rejected"))
        #expect(cli.read("state/readings/main.json").isEmpty)
    }

    @Test(arguments: ["seven_day", "five_hour"])
    func aUseRunPastTheCapShowsTheAccountLimitedUntilThatWindowResets(window: String) throws {
        let cli = try setUp([login()])
        defer { cli.cleanup() }
        let now = Int(Date().timeIntervalSince1970)
        let resets = ["five_hour": now + 10_000, "seven_day": now + 400_000]
        // The probe reports use past the cap in one window, as the client does once it is spent.
        let entries = ["five_hour", "seven_day"].map { name in
            let used = name == window ? "1.5" : "0.2"
            return "\"\(name)\":{\"utilization\":\(used),\"resetsAt\":\(resets[name] ?? 0)}"
        }
        let stream =
            "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\","
            + "\"unifiedWindows\":{\(entries.joined(separator: ","))}}}\n"
            + "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"OK\"}\n"
        try cli.fake("probe.jsonl", stream)
        let out = try cli.run(["refresh"])
        #expect(out.status == 0)
        let shown = String(decoding: out.stdout, as: UTF8.self)
        #expect(
            shown.contains(
                window == "seven_day"
                    ? "main: read (5 hour 20.0%, week 100.0%)"
                    : "main: read (5 hour 100.0%, week 20.0%)"))
        let status = try cli.run(["status", "--json"])
        let doc = try #require(JSONSerialization.jsonObject(with: status.stdout) as? [String: Any])
        let rows = try #require(doc["accounts"] as? [[String: Any]])
        let row = try #require(rows.first { $0["label"] as? String == "main" })
        #expect(row["state"] as? String == "limited")
        #expect(row["error"] == nil || row["error"] is NSNull)
        let name = window == "seven_day" ? "weekly" : "fiveHour"
        let limited = try #require(row["limited"] as? [String: Any])
        #expect(limited["window"] as? String == name)
        // It stays limited until that window's reset time.
        let shownWindow = try #require(row[name] as? [String: Any])
        #expect(shownWindow["usedPercent"] as? Double == 100)
        let until = try #require(limited["until"] as? String)
        #expect(until == shownWindow["resetsAt"] as? String)
    }

    @Test func anUnknownLabelAndAMissingConfigAreRefused() throws {
        let cli = try setUp([login()])
        defer { cli.cleanup() }
        #expect(try cli.run(["refresh", "--label", "nope"]).status != 0)
        let bare = try CLIHome()
        defer { bare.cleanup() }
        #expect(try bare.run(["refresh"]).status != 0)
    }
}
