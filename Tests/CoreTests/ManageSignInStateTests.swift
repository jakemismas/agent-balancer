import Foundation
import Testing

@testable import Core

/// A folder account reads as signed in only when a check has seen it signed in, the open window
/// follows the status file, and the panel's texts say what they should.
extension ManageViewModelTests {
    /// A fake agent-balancer in `home` that logs each call and succeeds.
    static func loggingTool(in home: URL) throws -> (exe: URL, log: URL) {
        let exe = home.appendingPathComponent("tool-bin/agent-balancer")
        let log = home.appendingPathComponent("tool-calls.log")
        try FileManager.default.createDirectory(
            at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            echo "$*" >> "\(log.path)"
            echo "Fine: $1"
            exit 0
            """
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return (exe, log)
    }

    static func lines(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
            .map(String.init)
    }

    /// The row the real status builder writes for `label`.
    static func row(_ document: StatusDocument?, _ label: String) throws -> AccountStatus {
        try #require(document?.accounts.first { $0.label == label })
    }

    // MARK: Sign-in evidence, with the shapes the tool writes

    @Test @MainActor func aNewFolderIsNotSignedInUntilACheckSeesItSignedIn() async throws {
        let folders = FolderAccountsTests()
        let (t, context) = try folders.setUp()
        defer { withExtendedLifetime(t) {} }
        let tool = try Self.loggingTool(in: t.home)
        let vm = ManageViewModel(
            context: context, runner: CLIRunner(context: context, candidates: [tool.exe]),
            clock: { Self.now })
        vm.windowOpened()
        var draft = AddDraft()
        draft.label = "spare"
        draft.email = "acct@example.com"
        draft.kind = Kind.folder
        draft.stage = .added
        func signInStep() throws -> AddStep {
            try #require(vm.addSteps(draft).first { $0.id == 3 })
        }

        // Right after `add --kind folder`, the tool writes the folder's row as `not_linked`.
        var row = try Self.row(try StatusBuilder.rebuild(context: context), "spare")
        #expect(row.error?.code == "not_linked")
        #expect(row.planTier == nil)
        vm.statusMayHaveChanged()
        vm.selection = "spare"
        var panel = try #require(vm.panel)
        #expect(panel.signInText == "Not signed in")
        #expect(!panel.signedIn)
        #expect(panel.signIn?.title == "Sign in...")
        #expect(panel.signIn?.enabled == false)
        let listed = try #require(vm.rows.first { $0.label == "spare" })
        #expect(!listed.signedIn)
        #expect(listed.subtitle == "Not signed in")
        #expect(listed.accessibilityLabel == "spare, folder account, not signed in")
        #expect(try signInStep().state == .todo)
        #expect(try !signInStep().actionEnabled)
        await vm.signIn("spare")
        #expect(Self.lines(tool.log).isEmpty)

        // After `link`, the row is `ok` with no sign-in check behind it.
        _ = try folders.link(context)
        row = try Self.row(try StatusBuilder.rebuild(context: context), "spare")
        #expect(row.state == "ok")
        #expect(row.linked == true)
        #expect(row.planTier == nil)
        vm.statusMayHaveChanged()
        panel = try #require(vm.panel)
        #expect(panel.signInText == "Not signed in")
        #expect(!panel.signedIn)
        #expect(panel.signIn?.enabled == true)
        #expect(vm.rows.first { $0.label == "spare" }?.signedIn == false)
        #expect(try signInStep().state == .todo)
        #expect(try signInStep().actionEnabled)
        await vm.signIn("spare")
        #expect(Self.lines(tool.log) == ["login spare --browser"])

        // After a check that saw it signed in, which is what `login --browser` records.
        var observations = StatusObservations()
        observations.auth["spare"] = AuthObservation(
            error: nil, planTier: "max_20x", loginExpiresAt: nil, signedIn: true)
        row = try Self.row(
            try StatusBuilder.rebuild(context: context, observations: observations), "spare")
        #expect(row.planTier == "max_20x")
        vm.statusMayHaveChanged()
        panel = try #require(vm.panel)
        #expect(panel.signInText == "Signed in")
        #expect(panel.signedIn)
        #expect(panel.signIn == nil)
        #expect(panel.emailLine == "acct@example.com \u{00B7} max_20x")
        #expect(vm.rows.first { $0.label == "spare" }?.subtitle == "Signed in")
        #expect(try signInStep().state == .done)
        #expect(try !signInStep().actionEnabled)
    }

    @Test @MainActor func aFolderThatIsNotLinkedIsNotSignedInWhateverItsTier() async throws {
        let fake = try Fake()
        // As this version writes a folder row: with `signInCheck`, here before any check.
        try fake.status(
            changing: "fol-ok",
            [
                "linked": false, "state": "error", "signInCheck": NSNull(),
                "error": ["code": "not_linked", "text": "Settings not shared."],
            ])
        let vm = Self.model(fake)
        vm.selection = "fol-ok"
        let panel = try #require(vm.panel)
        #expect(panel.signInText == "Not signed in")
        #expect(!panel.signedIn)
        #expect(panel.signIn?.enabled == false)
        #expect(vm.rows.first { $0.label == "fol-ok" }?.signedIn == false)
        await vm.signIn("fol-ok")
        #expect(fake.calls().isEmpty)
    }

    @Test @MainActor func aTierThatIsNotPlainIsNoEvidenceAndIsNeverShown() throws {
        let fake = try Fake()
        try fake.status(changing: "fol-ok", ["planTier": "max\u{202E}x"])
        let vm = Self.model(fake)
        vm.selection = "fol-ok"
        #expect(vm.panel?.signInText == "Not signed in")
        #expect(vm.panel?.emailLine == "fol-ok@example.com")
    }

    // MARK: The open window follows the status file

    @Test @MainActor func theOpenWindowFollowsTheStatusFileAndAClosedOneDoesNot() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        var draft = AddDraft()
        draft.label = "fol-unlinked"
        draft.kind = Kind.folder
        draft.stage = .added
        #expect(vm.addSteps(draft)[1].state == .todo)
        // `link` in Terminal rewrites the status; a closed window does not read it.
        try fake.status(changing: "fol-unlinked", ["linked": true])
        vm.statusMayHaveChanged()
        #expect(vm.addSteps(draft)[1].state == .todo)
        vm.windowOpened()
        #expect(vm.isOpen)
        #expect(vm.addSteps(draft)[1].state == .done)
        #expect(vm.addSteps(draft)[2].actionEnabled)
        try fake.status(changing: "fol-unlinked", ["linked": false])
        vm.statusMayHaveChanged()
        #expect(vm.addSteps(draft)[1].state == .todo)
        #expect(!vm.addSteps(draft)[2].actionEnabled)
        vm.windowClosed()
        try fake.status(changing: "fol-unlinked", ["linked": true])
        vm.statusMayHaveChanged()
        #expect(vm.addSteps(draft)[1].state == .todo)
    }

    // MARK: Panel texts

    @Test @MainActor func theTokenTipSaysWhereTheFileIsAndTheDateTipSaysWhatADateDoes() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "tok-ok"
        let panel = try #require(vm.panel)
        #expect(
            panel.tokenTip
                == "Its token, once saved, sits in a file under ~/.agent-balancer. The tool uses it only while no other user can read that file."
        )
        #expect(panel.endsOnTip == ManageTips.endsOn)
        #expect(Self.sentenceCount(ManageTips.endsOn) == 1)
        #expect(ManageTips.endsOn.contains("only a date you know"))
        #expect(ManageTips.all().contains(ManageTips.endsOn))
    }

    @Test @MainActor func aFolderPanelShowsThePlanTierOnTheEmailLineAndATokenPanelDoesNot()
        throws
    {
        let fake = try Fake()
        try fake.status(changing: "tok-ok", ["planTier": "max_20x"])
        let vm = Self.model(fake)
        vm.selection = "fol-ok"
        #expect(vm.panel?.emailLine == "fol-ok@example.com \u{00B7} max_20x")
        vm.selection = "tok-ok"
        #expect(vm.panel?.emailLine == "tok-ok@example.com")
    }

    @Test @MainActor func theFolderPathComesFromTheLabelNeverFromTheStatusFile() throws {
        let fake = try Fake()
        try fake.status(changing: "fol-ok", ["configDir": "~/$(touch y)/.claude"])
        let vm = Self.model(fake)
        vm.selection = "fol-ok"
        #expect(vm.panel?.folderPath == "~/.agent-balancer/accounts/fol-ok/.claude")
    }

    @Test @MainActor func everyListRowKeepsItsEndStateWhateverItsSignInState() throws {
        let fake = try Fake()
        try fake.status(changing: "main", ["endsAt": "2026-11-16"])
        let vm = Self.model(fake)
        let rows = Dictionary(uniqueKeysWithValues: vm.rows.map { ($0.label, $0) })
        #expect(rows["tok-out"]?.subtitle == "Signed out \u{00B7} ending soon")
        #expect(rows["main"]?.subtitle == "Your login \u{00B7} ends Nov 16")
        try fake.status(changing: "fol-out", ["endingSoon": true])
        vm.reload()
        #expect(
            vm.rows.first { $0.label == "fol-out" }?.subtitle == "Signed out \u{00B7} ending soon")
    }

    // MARK: The menu's fix action

    @Test func onlyTheThreeSignInCodesCarryTheFixAction() throws {
        let codes = [
            "login_rejected", "token_missing", "not_linked", "wrong_account", "check_failed",
            "plan_changed", "duplicate_login", "settings_changed",
        ]
        let fixable: Set<String> = ["login_rejected", "token_missing", "not_linked"]
        for code in codes {
            let json = """
                { "schemaVersion": 1, "accounts": [ { "label": "a", "role": "pool",
                  "state": "error", "error": { "code": "\(code)", "text": "Text." } } ] }
                """
            guard case .loaded(let snapshot) = StatusSnapshot.parse(Data(json.utf8)) else {
                Issue.record("\(code) did not decode")
                continue
            }
            let row = MenuBuilder.row(snapshot.accounts[0], staleAfter: 3600)
            var manageable = false
            if case .error(let model) = row.body { manageable = model.manageable }
            #expect(manageable == fixable.contains(code), "\(code)")
        }
    }
}

extension MenuControllerTests {
    @Test @MainActor func eachPassOfTheFileLoopAlsoTellsTheManageWindow() async throws {
        let fake = try Fake()
        try fake.writeConfig()
        try fake.writeStatus(generatedAt: Date())
        var timing = MenuTiming()
        timing.fileReadSeconds = 0.05
        timing.refreshSecondsOverride = 3600
        timing.statusPollSeconds = 3600
        let controller = MenuController(context: fake.context, runner: fake.runner, timing: timing)
        var passes = 0
        controller.afterFileRead = { passes += 1 }
        controller.start()
        let seen = await Self.waitFor(300) { passes >= 2 }
        controller.stop()
        #expect(seen)
    }
}

/// Guards that tests elsewhere did not reach: the busy rule, the sign-in timeout, the bar's safe
/// pass, the add date rule, the account-database home and the tool's standard input.
extension ManageViewModelTests {
    /// A tool at a fresh path that runs `body`, a shell script body.
    static func tool(_ body: String) throws -> (exe: URL, home: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ab-tool-\(UUID().uuidString)")
        let exe = home.appendingPathComponent("bin/agent-balancer")
        try FileManager.default.createDirectory(
            at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body + "\n").write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return (exe, home)
    }

    @Test @MainActor func aSecondCommandWhileOneRunsIsRefused() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        let first = Task { await vm.run(.setEndingSoon(label: "tok-ok", on: true)) }
        await Self.waitUntilBusy(vm)
        #expect(vm.busy)
        #expect(await vm.run(.setEnds(label: "tok-ok", date: nil)) == false)
        #expect(await first.value)
        #expect(fake.calls() == ["config set tok-ok ending-soon true"])
    }

    @Test @MainActor func aSignInGetsTheLongTimeoutAndEveryOtherCommandTheShortOne() async throws {
        let fake = try Fake()
        let slow = try Self.tool("sleep 1\necho Done.")
        defer { try? FileManager.default.removeItem(at: slow.home) }
        let vm = ManageViewModel(
            context: fake.context, runner: CLIRunner(context: fake.context, candidates: [slow.exe]),
            clock: { Self.now }, timeoutSeconds: 0.3, loginTimeoutSeconds: 20)
        #expect(await vm.run(.login(label: "tok-out")))
        #expect(await vm.run(.loginBrowser(label: "fol-out")))
        #expect(await vm.run(.setEndingSoon(label: "tok-ok", on: true)) == false)
        #expect(vm.bar?.text == "The command timed out.")
        let defaults = Self.model(fake)
        #expect(defaults.loginTimeoutSeconds == 600)
        #expect(defaults.timeoutSeconds == 60)
    }

    @Test @MainActor func theBarShowsTheToolsOutputThroughTheSafePass() async throws {
        let fake = try Fake()
        let loud = try Self.tool(#"printf 'Saved \033[31mred\342\200\256 now\n'"#)
        defer { try? FileManager.default.removeItem(at: loud.home) }
        let vm = ManageViewModel(
            context: fake.context, runner: CLIRunner(context: fake.context, candidates: [loud.exe]),
            clock: { Self.now })
        #expect(await vm.run(.setEndingSoon(label: "tok-ok", on: true)))
        let text = try #require(vm.bar?.text)
        #expect(text.contains("\\u{1b}"))
        #expect(text.contains("\\u{202e}"))
        #expect(!text.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x202E })
    }

    /// The bar's line cuts a token the tool printed before its safe pass: a failed run's line, a
    /// refused browser sign-in's error line and the "Signed in." line of one that worked. The
    /// runner already cuts tokens from what it captures, so the lines go to the bar's own line
    /// rules as they are, and through a run as well.
    @Test @MainActor func theBarShowsNoTokenTheToolPrinted() async throws {
        /// A yes or no only, so a failure never prints the token.
        func cut(_ text: String?, _ token: String) -> Bool {
            guard let text else { return false }
            return text.contains(Scrubber.redacted) && !text.contains(token)
                && !text.contains("sk-" + "ant-")
        }
        for token in [Canaries.oauthRealShape(), Canaries.oauth(), Canaries.apiKey()] {
            let failed = cut(ManageViewModel.firstLine("Could not save \(token).\nMore."), token)
            #expect(failed, "a failed run")
            let refused = cut(
                ManageViewModel.signInAnswer(
                    RunOutput(
                        status: 1, stdout: "Opening your browser.\n",
                        stderr: "Error \(token) was refused.\n", timedOut: false, truncated: false),
                    ok: false), token)
            #expect(refused, "a refused browser sign-in")
            let signedIn = cut(
                ManageViewModel.signInAnswer(
                    RunOutput(
                        status: 0, stdout: "Opening your browser.\nSigned in. \(token)\n",
                        stderr: "", timedOut: false, truncated: false),
                    ok: true), token)
            #expect(signedIn, "a browser sign-in that worked")
        }

        // The same lines printed by a tool, as the bar shows them after the run.
        let token = Canaries.oauthRealShape()
        let fake = try Fake()
        let items: [(command: ManageCommand, body: String, ok: Bool)] = [
            (
                .setEndingSoon(label: "tok-ok", on: true),
                "echo 'Could not save \(token).' >&2\nexit 1", false
            ),
            (
                .loginBrowser(label: "fol-out"),
                "echo 'Opening your browser.'\necho 'Error \(token) was refused.' >&2\nexit 1",
                false
            ),
            (
                .loginBrowser(label: "fol-out"),
                "echo 'Opening your browser.'\necho 'Signed in. \(token)'", true
            ),
        ]
        for item in items {
            let tool = try Self.tool(item.body)
            defer { try? FileManager.default.removeItem(at: tool.home) }
            let vm = ManageViewModel(
                context: fake.context,
                runner: CLIRunner(context: fake.context, candidates: [tool.exe]),
                clock: { Self.now })
            #expect(await vm.run(item.command) == item.ok, "\(item.command)")
            let shown = cut(vm.bar?.text, token)
            #expect(shown, "\(item.command)")
        }
    }

    @Test func anAddWithAnEndDateBeforeTodayOrNotADateBuildsNothing() {
        for day in ["2020-01-01", "2026-11-01", "2026-13-45", "soon", ""] {
            let command = ManageCommand.add(
                label: "spare", email: nil, kind: Kind.token, end: .on(day))
            #expect(command.arguments(now: Self.now) == nil, "\(day)")
        }
        let later = ManageCommand.add(
            label: "spare", email: nil, kind: Kind.token, end: .on("2026-11-20"))
        #expect(later.arguments(now: Self.now) == ["add", "spare", "--ends", "2026-11-20"])
    }

    @Test func theAccountDatabaseHomeIsProtectedWhateverHomeSays() throws {
        let entry = try #require(getpwuid(getuid()))
        let dir = try #require(entry.pointee.pw_dir)
        let home = String(cString: dir)
        #expect(try RenderOutput.homes().contains { $0.path == home })
        // A folder inside that home's .claude is refused, read only: nothing is made.
        #expect(throws: ToolError.self) {
            try RenderOutput.folder(
                "build/renders",
                currentDirectoryPath: home + "/.claude/ab-never-made",
                homes: RenderOutput.homes())
        }
    }

    @Test func theToolGetsAPipeOnStandardInputEvenWhenTheAppHasATerminal() throws {
        let fake = try Fake()
        let probe = try Self.tool("if [ -t 0 ]; then echo terminal; else echo pipe; fi")
        defer { try? FileManager.default.removeItem(at: probe.home) }
        var main: Int32 = -1
        var other: Int32 = -1
        guard openpty(&main, &other, nil, nil, nil) == 0 else {
            Issue.record("no pseudo-terminal")
            return
        }
        // This process's own standard input is a terminal while the tool runs, as for an app
        // started from Terminal.
        let saved = dup(0)
        dup2(other, 0)
        defer {
            if saved >= 0 {
                dup2(saved, 0)
                close(saved)
            }
            close(other)
            close(main)
        }
        #expect(isatty(0) == 1)
        let out = try CLIRunner(context: fake.context, candidates: [probe.exe]).run(["x"])
        #expect(out.stdout == "pipe\n")
    }
}
