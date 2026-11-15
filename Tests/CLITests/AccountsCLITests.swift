import Foundation
import Testing

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

private func tail(_ n: Int = 40) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    return String((0..<n).map { _ in alphabet.randomElement()! })
}

private let refusal = "Run this in your own terminal, outside a Claude Code session."

/// End-to-end tests of init, doctor, config and link against the fake `claude`.
@Suite struct AccountsCLITests {
    func ready(label: String = "main") throws -> CLIHome {
        let h = try CLIHome()
        try h.fakeFixture("logged_in")
        let out = try h.run(["init", "--label", label])
        #expect(out.status == 0, "\(text(out.stderr))")
        return h
    }

    func config(_ h: CLIHome) throws -> [String: Any] {
        let data = try #require(h.read("config.json").data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: init

    @Test func initRegistersTheLoginAccount() throws {
        let h = try ready()
        defer { h.cleanup() }
        let c = try config(h)
        #expect(c["schemaVersion"] as? Int == 1)
        #expect(c["sharedSource"] as? String == "~/.claude")
        let probe = try #require(c["probe"] as? [String: Any])
        #expect(probe["safeMode"] as? Bool == true)
        let accounts = try #require(c["accounts"] as? [[String: Any]])
        #expect(accounts.count == 1)
        let a = accounts[0]
        #expect(a["label"] as? String == "main")
        #expect(a["kind"] as? String == "login")
        #expect(a["role"] as? String == "pool")
        #expect(a["email"] as? String == "main@example.com")
        #expect(a["expectedPlanTier"] as? String == "max_20x")
        #expect((a["accountKey"] as? String)?.count == 32)
        #expect(a["reserve"] == nil, "init alone writes no reserve line")
        #expect(a["configDir"] == nil)
        let raw = h.read("config.json")
        #expect(!raw.contains("lau" + "nchTemplate") && !raw.contains("claudePath"))
        #expect(h.expectPrivateModes().isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: h.dataRoot.appendingPathComponent("links.json").path))
    }

    @Test func initPrintsNoEmailAndAnEmailAppearsOnlyInConfig() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        let mail = "pat." + tail(6).lowercased() + "@" + "contoso" + ".test"
        try h.fake(
            "auth.json",
            "{\"loggedIn\":true,\"email\":\"\(mail)\",\"planTier\":\"max_20x\"}")
        let out = try h.run(["init", "--label", "main"])
        #expect(out.status == 0)
        #expect(!(text(out.stdout) + text(out.stderr)).contains(mail))
        // The status document is status output, so it may carry the email too.
        for url in h.dataEntries()
        where !["config.json", "status.json"].contains(url.lastPathComponent) {
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            #expect(!body.contains(mail), "\(url.lastPathComponent)")
        }
        #expect(h.read("config.json").contains(mail))
        let doctor = try h.run(["doctor"])
        #expect(!(text(doctor.stdout) + text(doctor.stderr)).contains(mail))
    }

    @Test func initNeedsALabelWhenInputIsNotATerminal() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        let out = try h.runOnTerminal(["init"])
        #expect(out.status == 1)
        #expect(text(out.stderr).contains("A label is required"))
        #expect(!FileManager.default.fileExists(atPath: h.dataRoot.path))
    }

    @Test func initUninstallAndPasteRefuseWhenInputIsNotATerminal() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        for args in [["init", "--label", "x"], ["uninstall"]] {
            let out = try h.runPiped(args, stdin: "uninstall\n")
            #expect(out.status == 1, "\(args)")
            #expect(text(out.stderr).contains("interactive terminal"), "\(args)")
        }
        #expect(!FileManager.default.fileExists(atPath: h.dataRoot.path))
    }

    @Test func initRefusesInAChatShell() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        let out = try h.runOnTerminal(
            ["init", "--label", "x"], env: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        #expect(out.status == 1)
        #expect(!FileManager.default.fileExists(atPath: h.dataRoot.path))
    }

    @Test func initWhenLoggedOutFailsAndWritesNothing() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_out", exit: 1)
        let out = try h.run(["init", "--label", "main"])
        #expect(out.status == 1)
        #expect(text(out.stderr).contains("not logged in"))
        #expect(!FileManager.default.fileExists(atPath: h.dataRoot.path))
    }

    @Test func initTwiceIsRefused() throws {
        let h = try ready()
        defer { h.cleanup() }
        let again = try h.run(["init", "--label", "other"])
        #expect(again.status == 1)
        #expect(text(again.stderr).contains("Already set up"))
    }

    @Test func initRejectsABadLabel() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        let out = try h.run(["init", "--label", "Bad Label"])
        #expect(out.status == 1)
        #expect(text(out.stderr).contains("not valid"))
    }

    @Test func initRecordsHookHashesAndNeverTheCommandText() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        let command = "/opt/tools/guard-" + tail(16)
        try h.settings(
            "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"\(command)\"}]}]}}"
        )
        let out = try h.run(["init", "--label", "main"])
        #expect(out.status == 0)
        #expect(text(out.stdout).contains("1 hook entries"))
        let links = h.read("links.json")
        #expect(links.contains("PreToolUse") && links.contains("commandHash"))
        #expect(!h.everything(out).contains(command))
        #expect(!h.everything(out).contains("guard-"))
    }

    @Test func initWithNoSettingsWritesAnEmptyRecord() throws {
        let h = try ready()
        defer { h.cleanup() }
        let links = try #require(
            try JSONSerialization.jsonObject(with: Data(h.read("links.json").utf8))
                as? [String: Any])
        let folder = try #require(links["defaultFolder"] as? [String: Any])
        #expect((folder["hooks"] as? [Any])?.isEmpty == true)
    }

    @Test func initAndDoctorWarnKeyInSettingsWithoutLeakingValues() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        let a = "sk-" + "ant-" + "api03-" + tail()
        let b = "sk-" + "ant-" + "oat01-" + tail()
        let c = "sk-" + "ant-" + "api03-" + tail()
        let d = "/bin/" + tail(12)
        let json = """
            {"apiKeyHelper":"\(d)","env":{"ANTHROPIC_API_KEY":"\(a)","ANTHROPIC_AUTH_TOKEN":"\(b)",
             "CLAUDE_CODE_\("OAUTH_TOKEN")":"\(c)"}}
            """
        try h.settings(json)
        let initOut = try h.run(["init", "--label", "main"])
        #expect(initOut.status == 0)
        #expect(text(initOut.stdout).contains("key_in_settings"))
        let doctor = try h.run(["doctor"])
        #expect(text(doctor.stdout).contains("key_in_settings"))
        for canary in [a, b, c, d] {
            #expect(!h.everything(initOut).contains(canary))
            #expect(!h.everything(doctor).contains(canary))
        }
    }

    @Test func initNeverWritesInsideTheClaudeFolder() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        try h.settings("{\"hooks\":{}}")
        let folder = h.home.appendingPathComponent(".claude")
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let body = try String(
            contentsOf: folder.appendingPathComponent("settings.json"), encoding: .utf8)
        _ = try h.run(["init", "--label", "main"])
        _ = try h.run(["doctor"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == before)
        #expect(
            try String(contentsOf: folder.appendingPathComponent("settings.json"), encoding: .utf8)
                == body)
    }

    // MARK: doctor

    @Test func doctorBeforeInitSaysOnlyThatSetupHasNotRun() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        let out = try h.run(["doctor"])
        #expect(out.status == 0)
        #expect(
            text(out.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                == "Setup has not run. Run `agent-balancer init`.")
    }

    @Test func doctorShowsPathVersionPlanAndNoEmail() throws {
        let h = try ready()
        defer { h.cleanup() }
        let out = try h.run(["doctor"])
        let s = text(out.stdout)
        #expect(out.status == 0, "\(s) \(text(out.stderr))")
        #expect(s.contains("claude: ~/.local/bin/claude"))
        #expect(s.contains("version: 2.1.0"))
        #expect(s.contains("account main (login, pool)"))
        #expect(s.contains("sign-in: signed in"))
        #expect(s.contains("plan: max_20x"))
        #expect(s.contains("login expires:"))
        #expect(s.contains("hooks: match the record"))
        #expect(!s.contains("example.com"))
        #expect(!s.contains(h.home.path))
        // The runner resolved the fake.
        #expect(h.fakeRecord("args.log").contains("auth status"))
    }

    @Test func doctorWarnsOfProtectedNamesByNameOnly() throws {
        let h = try ready()
        defer { h.cleanup() }
        let key = "sk-" + "ant-" + "api03-" + tail()
        let out = try h.run(
            ["doctor"], env: ["ANTHROPIC_API_KEY": key, "CLAUDE_CONFIG_DIR": "/somewhere/else"])
        let s = text(out.stdout)
        #expect(s.contains("ANTHROPIC_API_KEY") && s.contains("CLAUDE_CONFIG_DIR"))
        #expect(!(s + text(out.stderr)).contains(key))
        #expect(!s.contains("/somewhere/else"))
        // The child never saw them.
        let seen = h.fakeRecord("env-names.txt")
        #expect(!seen.contains("ANTHROPIC_API_KEY") && !seen.contains("CLAUDE_CONFIG_DIR"))
    }

    @Test func doctorWarnsOfTheStoredLoginFolderAndItsSiblingsByNameOnly() throws {
        let h = try ready()
        defer { h.cleanup() }
        let names = [
            "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_BRIDGE_OAUTH_TOKEN", "USE_STAGING_OAUTH",
        ]
        let env = Dictionary(uniqueKeysWithValues: names.map { ($0, "/somewhere/else") })
        let out = try h.run(["doctor"], env: env)
        let s = text(out.stdout)
        for name in names {
            #expect(s.contains("Warning: \(name) is set in this shell"), "\(name)")
        }
        #expect(!s.contains("/somewhere/else"))
        let seen = h.fakeRecord("env-names.txt")
        for name in names { #expect(!seen.contains(name), "\(name)") }
    }

    @Test func doctorPrintsAProtectedNameWithControlCharactersEscaped() throws {
        let h = try ready()
        defer { h.cleanup() }
        let out = try h.run(["doctor"], env: ["ANTHROPIC_\u{1B}]0;x\u{07}X": "1"])
        let s = text(out.stdout)
        #expect(s.contains(#"ANTHROPIC_\u{1b}]0;x\u{7}X"#))
        #expect(!s.contains("\u{1B}") && !s.contains("\u{07}"))
    }

    @Test func doctorReportsAMissingHookRecord() throws {
        let h = try ready()
        defer { h.cleanup() }
        try FileManager.default.removeItem(at: h.dataRoot.appendingPathComponent("links.json"))
        let out = try h.run(["doctor"])
        #expect(out.status == 1)
        #expect(
            text(out.stdout).contains(
                "Hook record missing. Run `agent-balancer link --accept-source-change` in Terminal."
            ))
        #expect(text(out.stdout).contains("settings_changed"))
    }

    @Test func doctorReportsRemovedHooks() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        try h.settings(
            "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"a\"}]}]}}")
        #expect(try h.run(["init", "--label", "main"]).status == 0)
        try h.settings("{\"hooks\":{}}")
        let out = try h.run(["doctor"])
        #expect(out.status == 1)
        #expect(text(out.stdout).contains("Settings changed."))
    }

    @Test func doctorReportsWrongAccountAndPlanChanged() throws {
        let h = try ready()
        defer { h.cleanup() }
        try h.fakeFixture("wrong_account")
        let a = try h.run(["doctor"])
        #expect(a.status == 1)
        #expect(text(a.stdout).contains("wrong_account"))
        try h.fakeFixture("plan_changed")
        let b = try h.run(["doctor"])
        #expect(text(b.stdout).contains("plan_changed"))
        try h.fakeFixture("logged_out", exit: 1)
        let c = try h.run(["doctor"])
        #expect(text(c.stdout).contains("login_rejected"))
    }

    @Test func doctorWarnsWhenTheLoginExpiresSoon() throws {
        let h = try ready()
        defer { h.cleanup() }
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86_400))
        try h.fake(
            "auth.json",
            "{\"loggedIn\":true,\"email\":\"main@example.com\",\"planTier\":\"max_20x\",\"loginExpiresAt\":\"\(soon)\"}"
        )
        let out = try h.run(["doctor"])
        #expect(out.status == 0)
        #expect(text(out.stdout).contains("login_expiring"))
    }

    @Test func doctorIgnoresAnExecutablePathInConfig() throws {
        let h = try ready()
        defer { h.cleanup() }
        let marker = h.home.appendingPathComponent("ran-marker")
        let evil = h.home.appendingPathComponent("evil-claude")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: evil, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: evil.path)
        var c = try config(h)
        c["claudePath"] = evil.path
        let data = try JSONSerialization.data(withJSONObject: c)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: h.dataRoot.appendingPathComponent("config.json").path)
        try data.write(to: h.dataRoot.appendingPathComponent("config.json"))
        let out = try h.run(["doctor"])
        #expect(out.status == 0, "\(text(out.stdout)) \(text(out.stderr))")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: config

    @Test func configShowHidesEmailsUnlessAsked() throws {
        let h = try ready()
        defer { h.cleanup() }
        let plain = text(try h.run(["config", "show"]).stdout)
        #expect(plain.contains("account main") && plain.contains("plan: max_20x"))
        #expect(!plain.contains("main@example.com"))
        let withEmails = text(try h.run(["config", "show", "--emails"]).stdout)
        #expect(withEmails.contains("main@example.com"))
    }

    @Test func configValidateAcceptsAndRejects() throws {
        let h = try ready()
        defer { h.cleanup() }
        #expect(text(try h.run(["config", "validate"]).stdout).contains("Config is valid."))
        var c = try config(h)
        c["schemaVersion"] = 7
        try JSONSerialization.data(withJSONObject: c).write(
            to: h.dataRoot.appendingPathComponent("config.json"))
        let bad = try h.run(["config", "validate"])
        #expect(bad.status == 1)
        #expect(text(bad.stderr).contains("version 7"))
    }

    @Test func configCommandsBeforeInitSaySetupHasNotRun() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        let out = try h.run(["config", "show"])
        #expect(out.status == 1)
        #expect(text(out.stderr).contains("Setup has not run"))
    }

    @Test func setMainWritesTheDefaultReserveAndClearMainRemovesIt() throws {
        let h = try ready()
        defer { h.cleanup() }
        let set = try h.run(["config", "set-main", "main"])
        #expect(set.status == 0)
        #expect(text(set.stdout).contains("5 days 50, 2 days 90, margin 5"))
        let a = try #require((try config(h)["accounts"] as? [[String: Any]])?.first)
        #expect(a["role"] as? String == "main")
        let reserve = try #require(a["reserve"] as? [String: Any])
        #expect(reserve["marginPercent"] as? Int == 5)
        #expect((reserve["points"] as? [Any])?.count == 2)
        let clear = try h.run(["config", "clear-main", "main"])
        #expect(clear.status == 0)
        let b = try #require((try config(h)["accounts"] as? [[String: Any]])?.first)
        #expect(b["role"] as? String == "pool" && b["reserve"] == nil)
    }

    @Test func setMainOnAnUnknownLabelFails() throws {
        let h = try ready()
        defer { h.cleanup() }
        let out = try h.run(["config", "set-main", "nobody"])
        #expect(out.status == 1)
        #expect(text(out.stderr).contains("No account is labelled"))
    }

    @Test func setChangesOneFieldEachWithABackup() throws {
        let h = try ready()
        defer { h.cleanup() }
        func account() throws -> [String: Any] {
            try #require((try config(h)["accounts"] as? [[String: Any]])?.first)
        }
        #expect(try h.run(["config", "set", "main", "email", "new@example.com"]).status == 0)
        #expect(try account()["email"] as? String == "new@example.com")
        #expect(try h.run(["config", "set", "main", "ends", "2099-12-31"]).status == 0)
        #expect(try account()["endsAt"] as? String == "2099-12-31")
        #expect(try h.run(["config", "set", "main", "ending-soon", "true"]).status == 0)
        #expect(try account()["endingSoon"] as? Bool == true)
        #expect(try h.run(["config", "set", "main", "label", "primary"]).status == 0)
        #expect(try account()["label"] as? String == "primary")
        #expect(try h.run(["config", "set", "refresh.backgroundMinutes", "30"]).status == 0)
        let refresh = try #require(try config(h)["refresh"] as? [String: Any])
        #expect(refresh["backgroundMinutes"] as? Int == 30)
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: h.dataRoot.appendingPathComponent("backups").path)
        #expect(backups.count == 5)
        #expect(h.expectPrivateModes().isEmpty)
    }

    @Test func setRejectsBadValues() throws {
        let h = try ready()
        defer { h.cleanup() }
        for args in [
            ["set", "main", "ends", "tomorrow"], ["set", "main", "ending-soon", "maybe"],
            ["set", "main", "label", "Bad Label"], ["set", "main", "email", "nope"],
            ["set", "main", "colour", "red"], ["set", "refresh.backgroundMinutes", "0"],
            ["set", "ghost", "email", "a@example.com"],
        ] {
            #expect(try h.run(["config"] + args).status == 1, "\(args)")
        }
    }

    // MARK: chat shell

    @Test func consentCommandsRefuseInAChatShell() throws {
        let h = try ready()
        defer { h.cleanup() }
        let before = h.read("config.json")
        let linksBefore = h.read("links.json")
        let commands: [[String]] = [
            ["config", "set-main", "main"], ["config", "clear-main", "main"],
            ["config", "set", "main", "email", "a@example.com"],
            ["config", "set", "refresh.backgroundMinutes", "30"],
            ["link", "--accept-source-change"],
        ]
        for args in commands {
            let out = try h.runOnTerminal(
                args, env: ["CLAUDE_CODE_CHILD_SESSION": ""], typing: "accept\n")
            #expect(out.status == 1, "\(args)")
            #expect(text(out.stderr).contains(refusal), "\(args)")
            #expect(!text(out.stderr).lowercased().contains("unset"), "\(args)")
        }
        #expect(h.read("config.json") == before)
        #expect(h.read("links.json") == linksBefore)
    }

    @Test func anEditorTerminalIsNotAChatShell() throws {
        let h = try ready()
        defer { h.cleanup() }
        let out = try h.run(["config", "set-main", "main"], env: ["CLAUDECODE": "1"])
        #expect(out.status == 0, "\(text(out.stderr))")
    }

    // MARK: link --accept-source-change

    func hookSettings(_ commands: [String]) -> String {
        let entries = commands.enumerated().map { i, c in
            "{\"matcher\":\"m\(i)\",\"hooks\":[{\"type\":\"command\",\"command\":\"\(c)\"}]}"
        }
        return "{\"hooks\":{\"PreToolUse\":[\(entries.joined(separator: ","))]}}"
    }

    @Test func acceptSourceChangeShowsTheDiffAndReRecordsAfterTheTypedWord() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        let keep = "keep-" + tail(10)
        let drop = "drop-" + tail(10)
        try h.settings(hookSettings([keep, drop]))
        #expect(try h.run(["init", "--label", "main"]).status == 0)
        let added = "added-" + tail(10)
        try h.settings(hookSettings([keep, added]))

        let wrong = try h.runOnTerminal(["link", "--accept-source-change"], typing: "nope\n")
        #expect(wrong.status == 1)
        #expect(try h.run(["doctor"]).status == 1)

        let out = try h.runOnTerminal(["link", "--accept-source-change"], typing: "accept\n")
        let s = text(out.stdout)
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(s.contains("added: 1") && s.contains("removed: 1"))
        #expect(s.contains("disableAllHooks: not present"))
        for command in [keep, drop, added] { #expect(!h.everything(out).contains(command)) }
        #expect(try h.run(["doctor"]).status == 0)
    }

    @Test func acceptSourceChangeWithNoLabelRestoresAMissingRecord() throws {
        let h = try ready()
        defer { h.cleanup() }
        try FileManager.default.removeItem(at: h.dataRoot.appendingPathComponent("links.json"))
        #expect(try h.run(["doctor"]).status == 1)
        let out = try h.runOnTerminal(["link", "--accept-source-change"], typing: "accept\n")
        #expect(out.status == 0, "\(text(out.stderr))")
        #expect(try h.run(["doctor"]).status == 0)
        #expect(h.expectPrivateModes().isEmpty)
    }

    @Test func linkNeedsTheFlagAndTakesNoLabelYet() throws {
        let h = try ready()
        defer { h.cleanup() }
        #expect(try h.run(["link"]).status == 1)
        #expect(
            try h.runOnTerminal(["link", "main", "--accept-source-change"], typing: "accept\n")
                .status == 1)
    }

    // MARK: safety

    @Test func everyCommandLeavesPrivateModes() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        try h.fakeFixture("logged_in")
        let steps: [[String]] = [
            ["init", "--label", "main"], ["doctor"], ["config", "show"], ["config", "validate"],
            ["config", "set-main", "main"], ["config", "set", "main", "ends", "2027-01-31"],
            ["config", "clear-main", "main"],
        ]
        for step in steps {
            _ = try h.run(step)
            #expect(h.expectPrivateModes().isEmpty, "after \(step)")
        }
        _ = try h.runOnTerminal(["link", "--accept-source-change"], typing: "accept\n")
        #expect(h.expectPrivateModes().isEmpty)
    }

    @Test func aSymlinkedBackupsFolderStopsAConfigChange() throws {
        let h = try ready()
        defer { h.cleanup() }
        let outside = h.home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: h.dataRoot.appendingPathComponent("backups"), withDestinationURL: outside)
        let before = h.read("config.json")
        let out = try h.run(["config", "set", "refresh.backgroundMinutes", "5"])
        #expect(out.status == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(h.read("config.json") == before)
    }

    @Test func canariesInEveryInputReachNoOutputOrDataFile() throws {
        let h = try CLIHome()
        defer { h.cleanup() }
        let oauth = "sk-" + "ant-" + "oat01-" + tail()
        let org = UUID().uuidString.lowercased()
        let orgName = "Northwind " + tail(6) + " Traders"
        let path = "/Users/" + "pat" + tail(4).lowercased() + "/work"
        try h.fake(
            "auth.json",
            "{\"loggedIn\":true,\"email\":\"main@example.com\",\"planTier\":\"max_20x\",\"orgId\":\"\(org)\",\"orgName\":\"\(orgName)\",\"extra\":\"\(oauth)\",\"configDirectory\":\"\(path)\"}"
        )
        try h.fake("stderr.txt", "noise \(oauth) \(org) \(path)\n")
        let initOut = try h.run(["init", "--label", "main"], env: ["AB_PLANTED": oauth])
        let doctor = try h.run(["doctor"], env: ["AB_PLANTED": oauth])
        for out in [initOut, doctor] {
            let all = h.everything(out)
            for canary in [oauth, org, orgName, path] { #expect(!all.contains(canary)) }
        }
        #expect(initOut.status == 0)
    }
}

extension AccountsCLITests {
    /// The names in the backups folder.
    func backups(_ h: CLIHome) -> Set<String> {
        let dir = h.dataRoot.appendingPathComponent("backups")
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    @Test func initOnAConfigWithNoLoginAccountKeepsEveryAccountAndBacksTheOldFileUp() throws {
        let h = try ready()
        defer { h.cleanup() }
        #expect(try h.run(["add", "lab", "--ends", "2099-12-31"]).status == 0)
        #expect(try h.run(["add", "spare", "--kind", "folder", "--ending-soon"]).status == 0)
        // Removing the pool login account leaves a config with no login account.
        let removed = try h.run(["remove", "main"])
        #expect(removed.status == 0, "\(text(removed.stderr))")
        let old = h.read("config.json")
        let kept = try #require(try config(h)["accounts"] as? [[String: Any]])
        #expect(kept.compactMap { $0["label"] as? String } == ["lab", "spare"])
        let before = backups(h)

        let out = try h.run(["init", "--label", "main2"])
        #expect(out.status == 0, "\(text(out.stderr))")
        let accounts = try #require(try config(h)["accounts"] as? [[String: Any]])
        #expect(accounts.compactMap { $0["label"] as? String } == ["lab", "spare", "main2"])
        for (index, entry) in kept.enumerated() {
            #expect(NSDictionary(dictionary: accounts[index]).isEqual(to: entry), "\(index)")
        }
        #expect(accounts[2]["kind"] as? String == "login")
        let added = backups(h).subtracting(before)
        #expect(added.count == 1)
        for name in added {
            let saved = h.dataRoot.appendingPathComponent("backups").appendingPathComponent(name)
            #expect((try? String(contentsOf: saved, encoding: .utf8)) == old)
        }
    }
}
