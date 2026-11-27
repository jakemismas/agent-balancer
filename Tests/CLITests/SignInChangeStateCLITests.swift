import Foundation
import Testing

@testable import Core

/// What the sign-in change tests read back: the registry, the status and the window.
enum SignInState {
    static func context(_ cli: CLIHome) -> ToolContext { ToolContext(home: cli.home, ambient: [:]) }

    static func saved(_ cli: CLIHome, _ label: String) throws -> Account {
        try #require(try ConfigStore(context: context(cli)).loadRequired().account(label))
    }

    static func edit(_ cli: CLIHome, _ change: (inout Config) -> Void) throws {
        let store = ConfigStore(context: context(cli))
        var config = try store.loadRequired()
        change(&config)
        try store.save(config)
    }

    /// The status row of `label`, read with no check.
    static func row(_ cli: CLIHome, _ label: String) throws -> [String: Any] {
        let out = try cli.run(["status", "--json", "--cached"])
        let doc = try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
        let rows = try #require(doc["accounts"] as? [[String: Any]])
        return try #require(rows.first { $0["label"] as? String == label })
    }

    static func code(_ cli: CLIHome, _ label: String) throws -> String? {
        (try row(cli, label)["error"] as? [String: Any])?["code"] as? String
    }

    /// The Manage window over the status file, with `label` selected.
    @MainActor static func window(_ cli: CLIHome, _ label: String) -> ManageViewModel {
        let vm = ManageViewModel(
            context: context(cli), runner: CLIRunner(context: context(cli), candidates: [cli.exe]))
        vm.windowOpened()
        vm.selection = label
        return vm
    }

    /// The default folder signed in as other@example.com on another plan.
    static let otherOnFiveX =
        #"{"loggedIn":true,"email":"other@example.com","planTier":"max_5x","subscriptionType":"max","#
        + #""loginExpiresAt":"2099-01-01T00:00:00Z"}"#

    static func pick(_ cli: CLIHome, _ args: [String] = []) throws -> [String: Any] {
        let out = try cli.run(["pick", "--json", "--dry-run"] + args)
        return try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
    }

    static func reason(_ answer: [String: Any], _ label: String) -> String? {
        let list = answer["candidates"] as? [[String: Any]] ?? []
        return list.first { $0["label"] as? String == label }?["reason"] as? String
    }
}

// MARK: #51, the recorded plan follows the email

extension SignInChangeReadingCLITests {
    @Test func anEmailChangeForgetsThePlanAndTheFirstPlacedCheckRecordsTheNew() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        // Ending soon, so a plan compared with the old one would end the account.
        try SignInState.edit(cli) { $0.accounts[0].endingSoon = true }
        // Signed out while the email changes, so its own check places nothing.
        try cli.fakeFixture("logged_out")
        #expect(try cli.run(["config", "set", "main", "email", "other@example.com"]).status == 0)
        let changed = try SignInState.saved(cli, "main")
        #expect(changed.email == "other@example.com" && changed.expectedPlanTier == nil)

        try cli.fake("auth.json", SignInState.otherOnFiveX)
        try SignInSwitch.reply(cli, week: 0.3, now: Date())
        #expect(try cli.run(["refresh"]).status == 0)
        #expect(try SignInState.saved(cli, "main").expectedPlanTier == "max_5x")
        let row = try SignInState.row(cli, "main")
        #expect(row["state"] as? String == "ok")
        #expect(row["planTier"] as? String == "max_5x")
        #expect(try SignInState.code(cli, "main") == nil)
    }

    @Test func theCheckAnEmailChangeRunsRecordsThePlanOfTheNewSignInItPlaces() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try SignInState.edit(cli) { $0.accounts[0].endingSoon = true }
        try cli.fake("auth.json", SignInState.otherOnFiveX)
        #expect(try cli.run(["config", "set", "main", "email", "other@example.com"]).status == 0)
        #expect(try SignInState.saved(cli, "main").expectedPlanTier == "max_5x")
        let row = try SignInState.row(cli, "main")
        #expect(row["state"] as? String == "ok")
        #expect(try SignInState.code(cli, "main") == nil)
    }

    @Test func anEmailChangeDropsThePlanEndTheOldSignInLeftSoStatusAndPickAgree() throws {
        for unreadable in [false, true] {
            let cli = try setUp(role: Role.pool)
            defer { cli.cleanup() }
            try SignInState.edit(cli) { $0.accounts[0].endingSoon = true }
            try SignInSwitch.storeOld(cli, "main", age: 60, now: Date())
            // The old sign-in's plan dropped, which ends an account marked ending soon.
            try cli.fake(
                "auth.json",
                #"{"loggedIn":true,"email":"main@example.com","planTier":"max_5x","#
                    + #""subscriptionType":"max","loginExpiresAt":"2099-01-01T00:00:00Z"}"#)
            #expect(try cli.run(["status", "--json"]).status == 0)
            #expect(try SignInState.row(cli, "main")["state"] as? String == "ended")

            try cli.fake("auth.json", unreadable ? "not a status" : SignInState.otherOnFiveX)
            #expect(
                try cli.run(["config", "set", "main", "email", "other@example.com"]).status == 0)
            let changed = try SignInState.row(cli, "main")["state"] as? String
            #expect(changed != "ended", "\(unreadable)")
            try cli.fake("auth.json", SignInState.otherOnFiveX)
            #expect(try cli.run(["status", "--json"]).status == 0)
            #expect(try SignInState.row(cli, "main")["state"] as? String == "ok", "\(unreadable)")
            #expect(try SignInState.code(cli, "main") == nil, "\(unreadable)")
            try SignInSwitch.reply(cli, week: 0.3, now: Date())
            #expect(try SignInState.pick(cli)["label"] as? String == "main", "\(unreadable)")
        }
    }

    @Test func theSameEmailAgainRecordsNoPlanForAnAccountWithNone() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try SignInState.edit(cli) { $0.accounts[0].expectedPlanTier = nil }
        for email in ["main@example.com", "Main@Example.COM"] {
            #expect(try cli.run(["config", "set", "main", "email", email]).status == 0)
            #expect(try SignInState.saved(cli, "main").expectedPlanTier == nil, "\(email)")
        }
    }
}

extension FolderAccountsCLITests {
    @Test func aFolderEmailChangeForgetsThePlanAndItsCheckRecordsTheNewSignInsPlan() throws {
        let cli = try setUp(login: false)
        defer { cli.cleanup() }
        try linked(cli)
        try SignInState.edit(cli) { $0.accounts[0].endingSoon = true }
        let dir = try folderPath(cli)
        try cli.fake(
            "auth.json",
            #"{"loggedIn":true,"email":"new@example.com","planTier":"max_5x","configDirectory":"\#(dir)"}"#
        )
        #expect(try cli.run(["config", "set", "spare", "email", "new@example.com"]).status == 0)
        #expect(try SignInState.saved(cli, "spare").expectedPlanTier == "max_5x")
        let row = try SignInState.row(cli, "spare")
        #expect(row["state"] as? String == "ok")
        #expect(row["planTier"] as? String == "max_5x")
        #expect(try SignInState.code(cli, "spare") == nil)
    }
}

// MARK: #52, a login row counts as signed in only for its current email

extension SignInChangeReadingCLITests {
    @Test @MainActor func aLoginEmailChangedByHandIsNotShownSignedIn() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        #expect(try cli.run(["status", "--json"]).status == 0)
        #expect(SignInState.window(cli, "main").panel?.signedIn == true)
        let text = cli.read("config.json")
        try NoFollowWriter(root: cli.dataRoot).put(
            Data(text.replacingOccurrences(of: "main@example.com", with: "new@example.com").utf8),
            folders: [], name: ConfigStore.fileName)
        #expect(try cli.run(["status", "--json", "--cached"]).status == 0)
        let vm = SignInState.window(cli, "main")
        let row = try #require(vm.rows.first { $0.label == "main" })
        #expect(!row.signedIn && row.subtitle == "Sign-in not confirmed")
        #expect(vm.panel?.signedIn == false)
        #expect(vm.panel?.signInText == "Sign-in not confirmed")
        // The row has no code, so the panel has no problem to give.
        #expect(vm.panel?.problem == nil)
    }

    @Test @MainActor func aCheckOfTheOldEmailThatSavesAfterTheChangeLeavesWrongAccount() throws {
        for unreadable in [false, true] {
            let cli = try setUp(role: Role.pool)
            defer { cli.cleanup() }
            // Fresh, so the refresh runs no probe and its first sign-in check is the one held.
            try SignInSwitch.storeOld(cli, "main", age: 60, now: Date())
            try cli.fake("hold-auth", "")
            let refresh = SignInRace.started(cli, ["refresh", "--label", "main"])
            #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-auth") })
            #expect(
                try cli.run(["config", "set", "main", "email", "other@example.com"]).status == 0)
            #expect(try SignInState.code(cli, "main") == "wrong_account")
            if unreadable { try cli.fake("auth.json", "not a status") }
            try cli.fake("go-auth", "")
            #expect(SignInRace.waitUntil { refresh.isDone })
            #expect(try SignInState.code(cli, "main") == "wrong_account", "\(unreadable)")
            let vm = SignInState.window(cli, "main")
            #expect(vm.rows.first { $0.label == "main" }?.signedIn == false, "\(unreadable)")
            #expect(vm.panel?.signInText == "Signed in as another account", "\(unreadable)")
            try cli.fakeFixture("logged_in")
            #expect(try cli.run(["status", "--json"]).status == 0)
            #expect(try SignInState.code(cli, "main") == "wrong_account", "\(unreadable)")
            #expect(try cli.run(["refresh", "--label", "main"]).status != 0)
            #expect(try SignInState.code(cli, "main") == "wrong_account", "\(unreadable)")
        }
    }
}

// MARK: #62, a rename takes the account's reading, leases and history along

extension SignInChangeReadingCLITests {
    /// A reading of weekly use `week` taken `age` seconds ago, its reset `days` out.
    func store(
        _ cli: CLIHome, _ label: String, week: Double, age: TimeInterval = 60, days: Double = 3
    )
        throws
    {
        let now = Date()
        let at = now.addingTimeInterval(-age)
        let windows = [
            WindowName.sevenDay: WindowReading(
                usedPercent: week,
                resetsAt: SignInSwitch.minute(now.addingTimeInterval(days * 86_400)),
                readAt: at),
            WindowName.fiveHour: WindowReading(
                usedPercent: 10, resetsAt: SignInSwitch.minute(now.addingTimeInterval(3_600)),
                readAt: at),
        ]
        try SignInSwitch.store(cli).save(Reading(readAt: at, windows: windows), label: label)
    }

    @Test func aRenameTakesTheAccountsReadingAndNeverTheOneStoredUnderItsNewLabel() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        let store = SignInSwitch.store(cli)
        try self.store(cli, "main", week: 10)
        // Left under the new label by another account, with too little room to be picked.
        try self.store(cli, "primary", week: 92)
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        #expect(try store.load(label: "main") == nil)
        #expect(try store.load(label: "primary")?.sevenDay?.usedPercent == 10)
        var answer = try SignInState.pick(cli)
        #expect(answer["label"] as? String == "primary")

        // A rename back finds no older reading under the label it left.
        try self.store(cli, "main", week: 92)
        #expect(try cli.run(["config", "set", "primary", "label", "main"]).status == 0)
        #expect(try store.load(label: "primary") == nil)
        #expect(try store.load(label: "main")?.sevenDay?.usedPercent == 10)
        answer = try SignInState.pick(cli)
        #expect(answer["label"] as? String == "main")

        // An account with no reading of its own is left with none.
        try store.delete(label: "main")
        try self.store(cli, "primary", week: 92)
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        #expect(try store.load(label: "primary") == nil)
        #expect(try store.load(label: "main") == nil)
    }

    @Test func addAndInitStartAnAccountWithNoReadingLeftUnderItsLabel() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        let store = SignInSwitch.store(cli)
        try self.store(cli, "lab", week: 80)
        #expect(try cli.run(["add", "lab"]).status == 0)
        #expect(try store.load(label: "lab") == nil)

        // `init` finds no login account once `main` is gone, and a reading left under `main`.
        #expect(try cli.run(["remove", "main"]).status == 0)
        try self.store(cli, "main", week: 80)
        let out = try cli.run(["init", "--label", "main"], stdin: "")
        #expect(out.status == 0)
        #expect(try store.load(label: "main") == nil)
    }

    @Test func anAccountAddedUnderARenamedLabelStartsWithNoReadingAndNeedsAFiveHourWindow()
        throws
    {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try self.store(cli, "main", week: 10)
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        #expect(try cli.run(["add", "main"]).status == 0)
        #expect(try SignInSwitch.store(cli).load(label: "main") == nil)
        let weekly = Int(
            SignInSwitch.minute(Date().addingTimeInterval(4 * 86_400)).timeIntervalSince1970)
        try cli.fake(
            "probe.jsonl",
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"#
                + #""seven_day":{"utilization":0.1,"resetsAt":\#(weekly)}}}}"# + "\n")
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "main"]).status == 0)
        let own = try #require(try SignInSwitch.store(cli).load(label: "main"))
        #expect(own.fiveHour == nil)
        #expect(own.sevenDay?.resetsAt?.timeIntervalSince1970 == Double(weekly))
        #expect(try cli.run(["config", "set-main", "main"]).status == 0)
        let answer = try SignInState.pick(cli, ["--exclude", "primary"])
        #expect(
            SignInState.reason(answer, "main") == "No 5-hour reading, which the main account needs."
        )
    }

    @Test func theThirdRouteJudgesTheMainAccountOnItsOwnWeeklyReset() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        let now = Date()
        try SignInSwitch.storeOld(cli, "main", age: 1_200, now: now)
        try SignInSwitch.reply(cli, week: 0.6, now: now)
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        #expect(try cli.run(["add", "main"]).status == 0)
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "main"]).status == 0)
        #expect(try cli.run(["config", "set-main", "main"]).status == 0)
        let answer = try SignInState.pick(cli)
        #expect(
            SignInState.reason(answer, "main")
                == "Weekly use 60.0% is above the reserve line of 50.0% minus a 5 point margin.")
        let out = try cli.run(["status", "--json"])
        let doc = try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
        let rows = try #require(doc["accounts"] as? [[String: Any]])
        let main = try #require(rows.first { $0["label"] as? String == "main" })
        let reserve = try #require(main["reserve"] as? [String: Any])
        #expect(reserve["linePercent"] as? Double == 50)
        let days = try #require(reserve["daysLeft"] as? Double)
        #expect(abs(days - 6) < 0.1)
    }

    @Test func openLeasesCountForTheRenamedAccountAndItsLaunchFileStays() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try self.store(cli, "main", week: 88)
        let launched = try cli.run(["pick", "--json"])
        #expect(launched.status == 0)
        let first = try #require(
            JSONSerialization.jsonObject(with: launched.stdout) as? [String: Any])
        let args = try #require(first["args"] as? [String])
        let file = URL(fileURLWithPath: args[1])
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        let leases = try LeaseStore(context: SignInState.context(cli))
            .current(now: Date(), leaseMinutes: 10)
        #expect(leases.map(\.label) == ["primary"])
        let answer = try SignInState.pick(cli)
        #expect(
            SignInState.reason(answer, "primary")
                == "Only 2.0% of the week is left, and 5% is needed.")
        // That pick ran the launch file upkeep, and the file whose lease is open stays.
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func historyFollowsTheAccountKeyAcrossARename() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        let key = try SignInState.saved(cli, "main").accountKey
        let history = ReadingHistory(context: SignInState.context(cli))
        func line(_ key: String, _ minutesAgo: Double, _ week: Double) -> HistoryLine {
            HistoryLine(
                accountKey: key, at: Date().addingTimeInterval(-minutesAgo * 60),
                source: ReadingSource.probe, state: "ok",
                weekly: HistoryWindow(usedPercent: week, resetsAt: nil), fiveHour: nil, fable: nil)
        }
        try history.append(line(key, 30, 11), label: "main")
        try history.append(line(key, 20, 12), label: "main")
        // A line of another account, left under the new label.
        try history.append(line(Account.makeKey(), 25, 99), label: "primary")
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        func weeks(_ label: String) throws -> [Double] {
            let out = try cli.run(["history", "--json", "--label", label])
            let doc = try #require(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
            let accounts = try #require(doc["accounts"] as? [[String: Any]])
            let readings = accounts.first?["readings"] as? [[String: Any]] ?? []
            return readings.compactMap {
                ($0["weekly"] as? [String: Any])?["usedPercent"] as? Double
            }
        }
        #expect(try weeks("primary") == [11, 12])
        #expect(try cli.run(["add", "main"]).status == 0)
        #expect(try weeks("main") == [])
    }

    /// The launch file a pick of `main` writes.
    func pickedFile(_ cli: CLIHome) throws -> URL {
        let launched = try cli.run(["pick", "--json"])
        #expect(launched.status == 0)
        let args = try #require(try SignInSwitch.answer(launched)["args"] as? [String])
        let file = URL(fileURLWithPath: args[1])
        #expect(file.deletingLastPathComponent().lastPathComponent == "main")
        return file
    }

    func launchEnv(_ file: URL) throws -> [String: Any] {
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return object["env"] as? [String: Any] ?? [:]
    }

    @Test func aTokenSaveUnderTheOldLabelLeavesTheRenamedAccountsLaunchFileWithoutAToken() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try self.store(cli, "main", week: 10)
        let file = try pickedFile(cli)
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        #expect(try cli.run(["add", "main"]).status == 0)
        try SignInSwitch.reply(cli, week: 0.3, now: Date())
        try cli.fake("setup-token.out", Canary.realShapeToken() + "\n")
        #expect(try cli.run(["login", "main"]).status == 0)
        let env = try launchEnv(file)
        let carriesToken = env[ProtectedEnv.tokenVariable] != nil
        #expect(!carriesToken)
        #expect(env[LaunchFiles.accountVariable] as? String == "main")

        // Its lease is open under the new label, so removing the new account leaves the file as
        // its pick wrote it.
        let written = try Data(contentsOf: file)
        #expect(try cli.run(["remove", "main"]).status == 0)
        #expect((try? Data(contentsOf: file)) == written)
        let leases = try LeaseStore(context: SignInState.context(cli))
            .current(now: Date(), leaseMinutes: 10)
        #expect(leases.map(\.label) == ["primary"])
    }

    @Test func removeOfTheOldLabelKeepsTheRenamedAccountsLeasedLaunchFile() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try self.store(cli, "main", week: 10)
        let file = try pickedFile(cli)
        let written = try Data(contentsOf: file)
        #expect(try cli.run(["config", "set", "main", "label", "primary"]).status == 0)
        #expect(try cli.run(["remove", "main"]).status == 0)
        #expect((try? Data(contentsOf: file)) == written)
        let leases = try LeaseStore(context: SignInState.context(cli))
            .current(now: Date(), leaseMinutes: 10)
        #expect(leases.map(\.label) == ["primary"])
    }
}

extension FolderAccountsCLITests {
    @Test func aRenameRefusedAtItsSaveMovesNoReadingAndNoLease() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try cli.fake(
            "auth-default.json",
            #"{"loggedIn":true,"email":"main@example.com","planTier":"max_20x","#
                + #""subscriptionType":"max","loginExpiresAt":"2099-01-01T00:00:00Z"}"#)
        let now = Date()
        let at = now.addingTimeInterval(-60)
        let windows = [
            WindowName.sevenDay: WindowReading(
                usedPercent: 88, resetsAt: SignInSwitch.minute(now.addingTimeInterval(3 * 86_400)),
                readAt: at),
            WindowName.fiveHour: WindowReading(
                usedPercent: 10, resetsAt: SignInSwitch.minute(now.addingTimeInterval(3_600)),
                readAt: at),
        ]
        let store = SignInSwitch.store(cli)
        try store.save(Reading(readAt: at, windows: windows), label: "main")
        let launched = try cli.run(["pick", "--json"])
        #expect(try SignInSwitch.answer(launched)["label"] as? String == "main")
        let line = "Only 2.0% of the week is left, and 5% is needed."
        #expect(SignInState.reason(try SignInState.pick(cli), "main") == line)

        // Another account's folder wider than 0700 makes the registry save refuse.
        let dir = try folderPath(cli)
        #expect(chmod(dir, 0o755) == 0)
        let rename = try cli.run(["config", "set", "main", "label", "primary"])
        #expect(chmod(dir, 0o700) == 0)
        #expect(rename.status == 1)
        #expect(try SignInState.saved(cli, "main").label == "main")
        #expect(try store.load(label: "main")?.sevenDay?.usedPercent == 88)
        #expect(try store.load(label: "primary") == nil)
        let leases = try LeaseStore(context: SignInState.context(cli))
            .current(now: Date(), leaseMinutes: 10)
        #expect(leases.map(\.label) == ["main"])
        #expect(SignInState.reason(try SignInState.pick(cli), "main") == line)
    }
}

// MARK: what an email change keeps, and what each check records

extension SignInChangeReadingCLITests {
    @Test func theSameEmailInOtherLetterCaseKeepsThePlanAndItsChange() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try cli.fakeFixture("plan_changed")
        #expect(try cli.run(["config", "set", "main", "email", "Main@Example.COM"]).status == 0)
        #expect(try SignInState.saved(cli, "main").expectedPlanTier == "max_20x")
        #expect(try SignInState.code(cli, "main") == "plan_changed")
    }

    @Test func anEmailChangeIntoAnotherSignInStillRecordsItsErrorEvent() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try SignInSwitch.storeOld(cli, "main", age: 60, now: Date())
        #expect(try cli.run(["status", "--json"]).status == 0)
        #expect(try cli.run(["config", "set", "main", "email", "other@example.com"]).status == 0)
        #expect(try SignInRace.eventTypes(cli).last == "main:error")
        #expect(try SignInState.code(cli, "main") == "wrong_account")
    }

    @Test func aFolderAccountAddedUnderALabelStartsWithNoReadingLeftThere() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        try SignInSwitch.storeOld(cli, "spare", age: 60, now: Date())
        #expect(try cli.run(["add", "spare", "--kind", "folder"]).status == 0)
        #expect(try SignInSwitch.store(cli).load(label: "spare") == nil)
    }

    @Test func aRefusedHistoryFileStopsOnlyTheListingsItMayHold() throws {
        let cli = try setUp(role: Role.pool)
        defer { cli.cleanup() }
        #expect(try cli.run(["add", "lab"]).status == 0)
        let history = ReadingHistory(context: SignInState.context(cli))
        for label in ["main", "lab"] {
            try history.append(
                HistoryLine(
                    accountKey: try SignInState.saved(cli, label).accountKey,
                    at: Date().addingTimeInterval(-600), source: ReadingSource.probe, state: "ok",
                    weekly: HistoryWindow(usedPercent: 11, resetsAt: nil), fiveHour: nil,
                    fable: nil), label: label)
        }
        // A link where a label no account holds keeps its file, which the reader refuses.
        let folder = cli.dataRoot.appendingPathComponent("state/history")
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("zzz.jsonl"),
            withDestinationURL: cli.home.appendingPathComponent("elsewhere.jsonl"))
        let token = try cli.run(["history", "--json", "--label", "lab"])
        #expect(token.status == 0)
        let doc = try SignInSwitch.answer(token)
        let accounts = try #require(doc["accounts"] as? [[String: Any]])
        #expect((accounts.first?["readings"] as? [[String: Any]])?.count == 1)
        // The login account may have held that label before a rename, so its listing stops.
        #expect(try cli.run(["history", "--json", "--label", "main"]).status == 1)
        #expect(try cli.run(["history", "--json"]).status == 1)
        // A refused file under the token account's own label stops its listing too.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("zzz.jsonl"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("lab.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("lab.jsonl"),
            withDestinationURL: cli.home.appendingPathComponent("elsewhere.jsonl"))
        #expect(try cli.run(["history", "--json", "--label", "lab"]).status == 1)
    }
}

extension TokenAccountsCLITests {
    @Test func aTokenAccountsEmailChangeKeepsItsReading() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try addLab(cli)
        try loginLab(cli)
        let file = cli.read("state/readings/lab.json")
        #expect(!file.isEmpty)
        #expect(try cli.run(["config", "set", "lab", "email", "lab-new@example.com"]).status == 0)
        #expect(cli.read("state/readings/lab.json") == file)
    }
}

extension FolderAccountsCLITests {
    @Test func aFolderCheckOfTheOldEmailThatReadsNoStatusLeavesWrongAccount() throws {
        let cli = try setUp(login: false)
        defer { cli.cleanup() }
        try linked(cli)
        try SignInSwitch.storeOld(cli, "spare", age: 60, now: Date())
        try cli.fake("hold-auth", "")
        let refresh = SignInRace.started(cli, ["refresh", "--label", "spare"])
        #expect(SignInRace.waitUntil { SignInRace.faked(cli, "held-auth") })
        #expect(try cli.run(["config", "set", "spare", "email", "new@example.com"]).status == 0)
        #expect(try SignInState.code(cli, "spare") == "wrong_account")
        try cli.fake("auth.json", "not a status")
        try cli.fake("go-auth", "")
        #expect(SignInRace.waitUntil { refresh.isDone })
        #expect(try SignInState.code(cli, "spare") == "wrong_account")
    }
}
