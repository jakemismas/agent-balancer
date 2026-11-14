import Foundation
import Testing

@testable import Core

/// The Manage accounts window's view model against a fake agent-balancer.
@Suite(.serialized, .localZone("America/Los_Angeles")) struct ManageViewModelTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-09T21:13:00Z")!

    static let accountsJson = """
        { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": null,
          "accounts": [
            { "label": "main", "email": "main@example.com", "role": "main", "kind": "login",
              "fullLogin": true, "state": "ok", "weekly": null },
            { "label": "tok-ok", "email": "tok-ok@example.com", "role": "pool", "kind": "token",
              "state": "ok", "loginExpiresAt": "2027-10-27T10:00:00Z", "loginExpiresSource": "estimate" },
            { "label": "tok-out", "email": "tok-out@example.com", "role": "pool", "kind": "token",
              "state": "error", "endingSoon": true,
              "error": { "code": "token_missing", "text": "No token." } },
            { "label": "tok-date", "role": "pool", "kind": "token", "state": "ok",
              "endsAt": "2026-11-16" },
            { "label": "fol-ok", "email": "fol-ok@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "configDir": "~/.agent-balancer/accounts/fol-ok/.claude",
              "linked": true, "state": "ok", "planTier": "max_20x" },
            { "label": "fol-out", "email": "fol-out@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "configDir": "~/.agent-balancer/accounts/fol-out/.claude",
              "linked": true, "state": "error",
              "error": { "code": "login_rejected", "text": "Logged out." } },
            { "label": "fol-unlinked", "email": "fol-unlinked@example.com", "role": "pool",
              "kind": "folder", "fullLogin": true, "configDir": "~/x/.claude", "linked": false,
              "state": "error", "error": { "code": "login_rejected", "text": "Logged out." } },
            { "label": "fol-wrong", "email": "fol-wrong@example.com", "role": "pool",
              "kind": "folder", "fullLogin": true, "configDir": "~/y/.claude", "linked": true,
              "state": "error", "error": { "code": "wrong_account", "text": "Folder is logged in as another account." } }
          ] }
        """

    /// A temporary home with a fake tool that logs each call.
    final class Fake {
        let home: URL
        let tool: URL
        let log: URL

        init(
            ambient: [String: String] = [:], statusJson: String = ManageViewModelTests.accountsJson
        )
            throws
        {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("ab-manage-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            tool = home.appendingPathComponent("bin/agent-balancer")
            log = home.appendingPathComponent("calls.log")
            self.ambient = ambient
            try FileManager.default.createDirectory(
                at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = """
                #!/bin/sh
                echo "$*" >> "\(log.path)"
                if [ -f "\(home.path)/fail-on" ] && [ "$*" = "$(cat "\(home.path)/fail-on")" ]; then
                  echo "Could not save that." >&2
                  exit 1
                fi
                if [ -f "\(home.path)/fail" ]; then
                  echo "Something went wrong with sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789" >&2
                  exit 1
                fi
                echo "Fine: $1"
                exit 0
                """
            try script.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tool.path)
            let writer = NoFollowWriter(root: ToolContext(home: home, ambient: [:]).dataRoot)
            try writer.put(Data(statusJson.utf8), folders: ["state"], name: "status.json")
        }

        let ambient: [String: String]

        deinit { try? FileManager.default.removeItem(at: home) }

        var context: ToolContext { ToolContext(home: home, ambient: ambient) }
        var runner: CLIRunner { CLIRunner(context: context, candidates: [tool]) }

        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func failNext() {
            FileManager.default.createFile(
                atPath: home.appendingPathComponent("fail").path, contents: Data())
        }

        /// Makes the one call with exactly these arguments fail.
        func failOn(_ arguments: String) throws {
            try arguments.write(
                to: home.appendingPathComponent("fail-on"), atomically: true, encoding: .utf8)
        }

        /// Rewrites the status file, as `config set-main` in Terminal or another writer would.
        func status(_ json: String) throws {
            let writer = NoFollowWriter(root: context.dataRoot)
            try writer.put(Data(json.utf8), folders: ["state"], name: "status.json")
        }

        /// The status file with one account's fields replaced, or that account left out.
        func status(changing label: String, _ fields: [String: Any]?) throws {
            let data = Data(ManageViewModelTests.accountsJson.utf8)
            var object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var accounts = try #require(object["accounts"] as? [[String: Any]])
            let index = try #require(accounts.firstIndex { $0["label"] as? String == label })
            if let fields {
                accounts[index].merge(fields) { _, new in new }
            } else {
                accounts.remove(at: index)
            }
            object["accounts"] = accounts
            let out = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try status(String(decoding: out, as: UTF8.self))
        }
    }

    @MainActor static func model(
        _ fake: Fake, settings: ManageSettings = ManageSettings()
    ) -> ManageViewModel {
        LocalTime.zone = TimeZone(identifier: "America/Los_Angeles")!
        return ManageViewModel(
            context: fake.context, runner: fake.runner, settings: settings, clock: { Self.now })
    }

    // MARK: The six command shapes

    @Test func everyArgumentArrayTheWindowCanBuild() {
        let day = "2026-11-16"
        let built: [[String]?] = [
            ManageCommand.add(label: "spare", email: nil, kind: Kind.token, end: .never)
                .arguments(now: Self.now),
            ManageCommand.add(
                label: "spare", email: "spare@example.com", kind: Kind.token, end: .soon
            )
            .arguments(now: Self.now),
            ManageCommand.add(label: "spare", email: nil, kind: Kind.token, end: .on(day))
                .arguments(now: Self.now),
            ManageCommand.add(label: "spare", email: nil, kind: Kind.folder, end: .never)
                .arguments(now: Self.now),
            ManageCommand.removeAccount(label: "spare").arguments(now: Self.now),
            ManageCommand.setEnds(label: "spare", date: day).arguments(now: Self.now),
            ManageCommand.setEnds(label: "spare", date: nil).arguments(now: Self.now),
            ManageCommand.setEndingSoon(label: "spare", on: true).arguments(now: Self.now),
            ManageCommand.setEndingSoon(label: "spare", on: false).arguments(now: Self.now),
            ManageCommand.login(label: "spare").arguments(now: Self.now),
            ManageCommand.loginBrowser(label: "spare").arguments(now: Self.now),
        ]
        let expected: [[String]] = [
            ["add", "spare"],
            ["add", "spare", "--email", "spare@example.com", "--ending-soon"],
            ["add", "spare", "--ends", day],
            ["add", "spare", "--kind", "folder"],
            ["remove", "spare"],
            ["config", "set", "spare", "ends", day],
            ["config", "set", "spare", "ends", "none"],
            ["config", "set", "spare", "ending-soon", "true"],
            ["config", "set", "spare", "ending-soon", "false"],
            ["login", "spare"],
            ["login", "spare", "--browser"],
        ]
        #expect(built.compactMap { $0 } == expected)
        let forbidden: Set<String> = [
            "link", "unlink", "set-main", "clear-main", "--paste", "email", "label", "init",
            "uninstall", "run", "refresh",
        ]
        for args in built.compactMap({ $0 }) {
            #expect(forbidden.isDisjoint(with: Set(args)))
            #expect(["add", "remove", "config", "login"].contains(args[0]))
        }
    }

    @Test func inputsThatCouldActAsOptionsOrOtherCommandsBuildNothing() {
        let bad = ["--paste", "-x", "Spare", "a b", "link", "a;b", "", "x/../y", "UPPER", "a\nb"]
        for label in bad where !ConfigValidator.isValidLabel(label) {
            #expect(ManageCommand.login(label: label).arguments() == nil)
            #expect(ManageCommand.loginBrowser(label: label).arguments() == nil)
            #expect(ManageCommand.removeAccount(label: label).arguments() == nil)
            #expect(ManageCommand.setEnds(label: label, date: nil).arguments() == nil)
            #expect(
                ManageCommand.add(label: label, email: nil, kind: Kind.token, end: .never)
                    .arguments() == nil)
        }
        #expect(
            ManageCommand.add(label: "ok", email: "--x@example.com", kind: Kind.token, end: .never)
                .arguments() == nil)
        #expect(
            ManageCommand.add(label: "ok", email: "a b@example.com", kind: Kind.token, end: .never)
                .arguments() == nil)
        #expect(
            ManageCommand.add(label: "ok", email: nil, kind: Kind.login, end: .never).arguments()
                == nil)
        #expect(
            ManageCommand.add(label: "ok", email: nil, kind: "folder --paste", end: .never)
                .arguments() == nil)
        #expect(
            ManageCommand.setEnds(label: "ok", date: "2020-01-01").arguments(now: Self.now) == nil)
        #expect(ManageCommand.setEnds(label: "ok", date: "soon").arguments(now: Self.now) == nil)
    }

    @Test func noArgumentArrayHoldsAToken() {
        let token = "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789"
        let commands: [ManageCommand] = [
            .add(label: token, email: nil, kind: Kind.token, end: .never),
            .login(label: token), .loginBrowser(label: token), .removeAccount(label: token),
        ]
        for command in commands { #expect(command.arguments() == nil) }
    }

    // MARK: Sign in, both modes

    @Test @MainActor func tokenSignInInCommandModeShowsTheCommandAndStartsNothing() async throws {
        let fake = try Fake()
        let vm = Self.model(fake, settings: ManageSettings(tokenSignIn: .showCommand))
        vm.selection = "tok-out"
        let control = try #require(vm.panel?.signIn)
        #expect(control.mode == .showCommand)
        #expect(control.command == "agent-balancer login tok-out")
        await vm.signIn("tok-out")
        #expect(fake.calls().isEmpty)
    }

    @Test @MainActor func tokenSignInInRunModeRunsLogin() async throws {
        let fake = try Fake()
        let vm = Self.model(fake, settings: ManageSettings(tokenSignIn: .run))
        vm.selection = "tok-out"
        #expect(vm.panel?.signIn?.mode == .run)
        await vm.signIn("tok-out")
        #expect(fake.calls() == ["login tok-out"])
        #expect(vm.bar?.command == "agent-balancer login tok-out")
    }

    @Test @MainActor func folderSignInInRunModeRunsLoginBrowser() async throws {
        let fake = try Fake()
        let vm = Self.model(fake, settings: ManageSettings(folderSignIn: .run))
        vm.selection = "fol-out"
        let control = try #require(vm.panel?.signIn)
        #expect(control.mode == .run)
        #expect(control.enabled)
        await vm.signIn("fol-out")
        #expect(fake.calls() == ["login fol-out --browser"])
    }

    @Test @MainActor func folderSignInInCommandModeStartsNothing() async throws {
        let fake = try Fake()
        let vm = Self.model(fake, settings: ManageSettings(folderSignIn: .showCommand))
        vm.selection = "fol-out"
        let control = try #require(vm.panel?.signIn)
        #expect(control.mode == .showCommand)
        #expect(control.command == "agent-balancer login fol-out --browser")
        await vm.signIn("fol-out")
        #expect(fake.calls().isEmpty)
    }

    @Test @MainActor func folderSignInWaitsForSharedSettings() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "fol-unlinked"
        let panel = try #require(vm.panel)
        #expect(panel.signIn?.enabled == false)
        #expect(panel.linkCommand == "agent-balancer link fol-unlinked")
        await vm.signIn("fol-unlinked")
        #expect(fake.calls().isEmpty)
    }

    @Test @MainActor func signInAgainShowsOnlyOnALoggedOutFolder() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "fol-ok"
        #expect(vm.panel?.signIn == nil)
        vm.selection = "fol-wrong"
        #expect(vm.panel?.signIn == nil)
        #expect(vm.panel?.problem?.title == "Wrong account")
        vm.selection = "fol-out"
        #expect(vm.panel?.signIn != nil)
        #expect(vm.panel?.signInTip?.contains("fol-out@example.com") == true)
    }

    // MARK: Panels

    @Test @MainActor func tokenPanelShowsNothingAboutFoldersOrLinks() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "tok-ok"
        let panel = try #require(vm.panel)
        #expect(panel.kind == .token)
        #expect(panel.folderPath == nil)
        #expect(panel.sharedText == nil)
        #expect(panel.linkCommand == nil)
        #expect(panel.tokenExpires == "Expires Oct 27, 2027")
        #expect(panel.signIn != nil)
    }

    @Test @MainActor func folderPanelShowsPathSharedSettingsAndEnds() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "fol-ok"
        let panel = try #require(vm.panel)
        #expect(panel.kind == .folder)
        #expect(panel.folderPath == "~/.agent-balancer/accounts/fol-ok/.claude")
        #expect(panel.sharedText == "Linked \u{00B7} checked 3 min ago")
        #expect(panel.sharedOK)
        #expect(panel.tokenExpires == nil)
        #expect(panel.remove?.enabled == true)
    }

    @Test @MainActor func loginAccountHasNothingToChange() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "main"
        let panel = try #require(vm.panel)
        #expect(panel.kind == .login)
        #expect(panel.isMain)
        #expect(panel.signIn == nil)
        #expect(panel.remove == nil)
        #expect(panel.canChangeEnds == false)
        vm.openRemove()
        #expect(vm.removeSheet == nil)
    }

    @Test @MainActor func listShowsLabelKindAndSignInState() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        let rows = Dictionary(uniqueKeysWithValues: vm.rows.map { ($0.label, $0) })
        #expect(rows["main"]?.subtitle == "Your login")
        #expect(rows["tok-ok"]?.subtitle == "351 days left")
        #expect(rows["tok-out"]?.subtitle == "Signed out \u{00B7} ending soon")
        #expect(rows["tok-date"]?.subtitle == "Ends Nov 16")
        #expect(rows["fol-ok"]?.subtitle == "Signed in")
        #expect(rows["fol-out"]?.signedIn == false)
        #expect(rows["tok-out"]?.accessibilityLabel == "tok-out, token account, signed out")
        #expect(rows["fol-ok"]?.accessibilityLabel == "fol-ok, folder account, signed in")
    }

    @Test @MainActor func removeIsOffForAMainAccountWithTheTerminalCommand() throws {
        let json = """
            { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z",
              "accounts": [ { "label": "boss", "role": "main", "kind": "token", "state": "ok" } ] }
            """
        let fake = try Fake(statusJson: json)
        let vm = Self.model(fake)
        let panel = try #require(vm.panel)
        #expect(panel.remove?.enabled == false)
        #expect(panel.remove?.terminalCommand == "agent-balancer remove boss")
        vm.openRemove()
        #expect(vm.removeSheet == nil)
    }

    // MARK: Ends

    @Test func changingTheEndChoiceRunsOneCommand() {
        #expect(
            ManageViewModel.endCommand(label: "fol-ok", to: .never)
                == .setEnds(label: "fol-ok", date: nil))
        #expect(
            ManageViewModel.endCommand(label: "fol-ok", to: .soon)
                == .setEndingSoon(label: "fol-ok", on: true))
        #expect(
            ManageViewModel.endCommand(label: "fol-ok", to: .on("2026-12-01"))
                == .setEnds(label: "fol-ok", date: "2026-12-01"))
    }

    @Test @MainActor func endChoiceRunsTheCommandAndShowsItInTheBar() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        await vm.changeEnds(label: "tok-ok", to: .on("2026-11-20"))
        #expect(fake.calls() == ["config set tok-ok ends 2026-11-20"])
        #expect(vm.bar?.command == "agent-balancer config set tok-ok ends 2026-11-20")
        #expect(vm.bar?.ok == true)
        await vm.changeEnds(label: "tok-ok", to: .on("2020-01-01"))
        #expect(fake.calls().count == 1)
        #expect(vm.bar?.ok == false)
    }

    // MARK: Add and Remove sheets

    @Test @MainActor func addingATokenAccountRunsAddThenLoginInRunMode() async throws {
        let fake = try Fake()
        let vm = Self.model(fake, settings: ManageSettings(tokenSignIn: .run))
        vm.openAdd()
        vm.add?.label = "spare"
        vm.add?.email = "spare@example.com"
        await vm.submitAdd()
        #expect(fake.calls() == ["add spare --email spare@example.com", "login spare"])
        #expect(vm.add?.stage == .added)
    }

    @Test @MainActor func addingATokenAccountInCommandModeRunsAddAndShowsLogin() async throws {
        let fake = try Fake()
        let vm = Self.model(fake, settings: ManageSettings(tokenSignIn: .showCommand))
        vm.openAdd()
        vm.add?.label = "spare"
        await vm.submitAdd()
        #expect(fake.calls() == ["add spare"])
        let steps = vm.addSteps(try #require(vm.add))
        #expect(steps.last?.command == "agent-balancer login spare")
        #expect(steps.last?.action == nil)
    }

    @Test @MainActor func addingAFolderAccountListsTheRemainingSteps() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.openAdd()
        vm.add?.label = "spare"
        vm.add?.kind = Kind.folder
        vm.add?.end = .on("2026-12-01")
        vm.add?.endDate = "2026-12-01"
        await vm.submitAdd()
        #expect(fake.calls() == ["add spare --kind folder --ends 2026-12-01"])
        let steps = vm.addSteps(try #require(vm.add))
        #expect(steps.map(\.id) == [1, 2, 3, 4])
        #expect(steps[0].state == .done)
        #expect(steps[1].command == "agent-balancer link spare")
        #expect(steps[2].actionEnabled == false)
        #expect(steps[3].command == "agent-balancer run spare")
    }

    @Test @MainActor func folderSignInStepStaysOffUntilLinked() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        var draft = AddDraft()
        draft.label = "fol-out"
        draft.kind = Kind.folder
        draft.stage = .added
        #expect(vm.addSteps(draft)[2].actionEnabled == true)
        draft.label = "fol-unlinked"
        #expect(vm.addSteps(draft)[2].actionEnabled == false)
        #expect(vm.addSteps(draft)[1].state == .todo)
    }

    @Test @MainActor func addFailureShowsTheToolsErrorText() async throws {
        let fake = try Fake()
        fake.failNext()
        let vm = Self.model(fake)
        vm.openAdd()
        vm.add?.label = "spare"
        await vm.submitAdd()
        #expect(vm.add?.stage == .form)
        let text = try #require(vm.add?.error)
        #expect(text.contains("Something went wrong"))
        #expect(!text.contains("sk-ant"))
        #expect(vm.bar?.ok == false)
    }

    @Test @MainActor func addFormRejectsBadInput() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        var draft = AddDraft(endDate: "2026-11-09")
        #expect(vm.addProblem(draft) != nil)
        draft.label = "Bad Label"
        #expect(vm.addProblem(draft) != nil)
        draft.label = "tok-ok"
        #expect(vm.addProblem(draft) == "That label is already used.")
        draft.label = "fresh"
        #expect(vm.addProblem(draft) == nil)
        draft.email = "not an email"
        #expect(vm.addProblem(draft) != nil)
    }

    /// A day before today, or text that is not a day, gives the reason the sheet shows under the
    /// form, which also keeps its Add button off; Add then runs nothing.
    @Test @MainActor func aRefusedEndDateShowsItsReasonAndLeavesAddOff() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.openAdd()
        vm.add?.label = "spare"
        for day in ["2026-11-08", "2020-01-01", "2026-13-45", "soon", ""] {
            vm.add?.end = .on(day)
            vm.add?.endDate = day
            #expect(vm.addProblem(try #require(vm.add)) == "Pick today or a later day.", "\(day)")
            await vm.submitAdd()
            #expect(fake.calls().isEmpty, "\(day)")
            #expect(vm.add?.stage == .form && vm.add?.error == nil, "\(day)")
        }
        // The day counts only while "On a date" is chosen.
        for end in [EndChoice.never, .soon] {
            vm.add?.end = end
            #expect(vm.addProblem(try #require(vm.add)) == nil, "\(end)")
        }
        // Today is accepted, and Add runs.
        vm.add?.end = .on("2026-11-09")
        vm.add?.endDate = "2026-11-09"
        #expect(vm.addProblem(try #require(vm.add)) == nil)
        await vm.submitAdd()
        #expect(fake.calls() == ["add spare --ends 2026-11-09"])
    }

    @Test @MainActor func submitAddWithALabelAlreadyInUseRunsNoCommand() async throws {
        let fake = try Fake()
        let vm = Self.model(fake, settings: ManageSettings(tokenSignIn: .run))
        for (label, kind) in [
            ("tok-ok", Kind.token), ("fol-ok", Kind.folder), ("main", Kind.token),
        ] {
            vm.openAdd()
            vm.add?.label = label
            vm.add?.kind = kind
            #expect(
                vm.addProblem(try #require(vm.add)) == "That label is already used.", "\(label)")
            await vm.submitAdd()
            #expect(fake.calls().isEmpty, "\(label)")
            #expect(vm.bar == nil, "\(label)")
            #expect(vm.add?.stage == .form && vm.add?.error == nil, "\(label)")
            vm.closeAdd()
        }
    }

    @Test @MainActor func theAddSheetShowsNoStepsBeforeTheAccountIsAdded() async throws {
        let fake = try Fake()
        let modes = [
            ManageSettings(tokenSignIn: .run, folderSignIn: .run),
            ManageSettings(tokenSignIn: .showCommand, folderSignIn: .showCommand),
        ]
        for settings in modes {
            let vm = Self.model(fake, settings: settings)
            vm.openAdd()
            for kind in [Kind.token, Kind.folder] {
                // No label, a new one, and labels the status already lists.
                for label in ["", "spare", "tok-out", "fol-out"] {
                    vm.add?.label = label
                    vm.add?.kind = kind
                    let draft = try #require(vm.add)
                    #expect(draft.stage == .form)
                    #expect(vm.addSteps(draft).isEmpty, "\(kind) \(label)")
                }
            }
        }
        #expect(fake.calls().isEmpty)
        // Once the account is added, the steps show.
        let vm = Self.model(fake)
        vm.openAdd()
        vm.add?.label = "spare"
        await vm.submitAdd()
        let added = try #require(vm.add)
        #expect(added.stage == .added)
        #expect(!vm.addSteps(added).isEmpty)
    }

    @Test @MainActor func removeNeedsTheLabelTypedBack() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "tok-ok"
        vm.openRemove()
        var draft = try #require(vm.removeSheet)
        #expect(draft.text.contains("chats stay"))
        #expect(!vm.canConfirmRemove(draft))
        await vm.confirmRemove()
        #expect(fake.calls().isEmpty)
        draft.typed = "tok-o"
        vm.removeSheet = draft
        await vm.confirmRemove()
        #expect(fake.calls().isEmpty)
        draft.typed = "tok-ok"
        vm.removeSheet = draft
        await vm.confirmRemove()
        #expect(fake.calls() == ["remove tok-ok"])
        #expect(vm.removeSheet == nil)
    }

    @Test @MainActor func removeSheetNamesWhatStaysOnDiskForAFolder() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "fol-ok"
        vm.openRemove()
        #expect(vm.removeSheet?.text.contains("folder") == true)
    }

    // MARK: Remove re-reads the status before it runs

    /// Opens the Remove sheet on a pool account and types its label back.
    @MainActor static func typedRemoveSheet(_ vm: ManageViewModel, _ label: String) throws {
        vm.selection = label
        vm.openRemove()
        var draft = try #require(vm.removeSheet)
        draft.typed = label
        vm.removeSheet = draft
        #expect(vm.canConfirmRemove(draft))
    }

    @Test @MainActor func removeRunsNothingForAnAccountThatBecameMainWhileTheSheetWasOpen()
        async throws
    {
        let fake = try Fake()
        let vm = Self.model(fake)
        try Self.typedRemoveSheet(vm, "tok-ok")
        try fake.status(changing: "tok-ok", ["role": "main"])
        await vm.confirmRemove()
        #expect(fake.calls().isEmpty)
        #expect(vm.removeSheet == nil)
        #expect(vm.selection == "tok-ok")
        #expect(vm.panel?.remove?.enabled == false)
        #expect(vm.panel?.remove?.terminalCommand == "agent-balancer remove tok-ok")
        #expect(vm.bar?.ok == false)
        #expect(vm.bar?.text.contains("main account") == true)
    }

    @Test @MainActor func removeRunsNothingForAnAccountThatIsGoneWhenConfirmed() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        try Self.typedRemoveSheet(vm, "tok-ok")
        try fake.status(changing: "tok-ok", nil)
        await vm.confirmRemove()
        #expect(fake.calls().isEmpty)
        #expect(vm.removeSheet == nil)
        #expect(vm.bar?.text.contains("no longer listed") == true)
    }

    @Test @MainActor func removeRunsNothingWhenTheStatusCannotBeReadOrTheKindChanged()
        async throws
    {
        let fake = try Fake()
        let vm = Self.model(fake)
        try Self.typedRemoveSheet(vm, "tok-ok")
        try fake.status("not a status document")
        await vm.confirmRemove()
        #expect(fake.calls().isEmpty)
        #expect(vm.removeSheet == nil)

        let other = try Fake()
        let vm2 = Self.model(other)
        try Self.typedRemoveSheet(vm2, "fol-ok")
        try other.status(changing: "fol-ok", ["kind": "login"])
        await vm2.confirmRemove()
        #expect(other.calls().isEmpty)
        #expect(vm2.removeSheet == nil)
    }

    @Test @MainActor func removeRunsOnceForAnAccountThatIsStillAPoolAccount() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        try Self.typedRemoveSheet(vm, "tok-ok")
        // A rewrite that keeps the role changes nothing.
        try fake.status(changing: "tok-ok", ["role": "pool"])
        await vm.confirmRemove()
        #expect(fake.calls() == ["remove tok-ok"])
        #expect(vm.removeSheet == nil)
    }

    @Test @MainActor func runItselfRefusesRemoveForAnAccountTheStatusNowNamesMain() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        #expect(vm.panel != nil)
        try fake.status(changing: "fol-ok", ["role": "main"])
        let ok = await vm.run(.removeAccount(label: "fol-ok"))
        #expect(ok == false)
        #expect(fake.calls().isEmpty)
        #expect(vm.bar?.text.contains("main account") == true)
        let main = await vm.run(.removeAccount(label: "main"))
        #expect(main == false)
        #expect(fake.calls().isEmpty)
    }

    // MARK: Every other action reads the status again before it runs

    @Test @MainActor func signInReadsTheStatusAgainBeforeItRuns() async throws {
        let fake = try Fake()
        let vm = Self.model(fake, settings: ManageSettings(folderSignIn: .run))
        vm.selection = "fol-out"
        #expect(vm.panel?.signIn?.enabled == true)
        // The folder lost its link after the panel was drawn.
        try fake.status(changing: "fol-out", ["linked": false])
        await vm.signIn("fol-out")
        // Or it was signed in from Terminal: the check that saw it writes the plan tier.
        try fake.status(
            changing: "fol-out", ["state": "ok", "error": NSNull(), "planTier": "max_20x"])
        await vm.signIn("fol-out")
        #expect(fake.calls().isEmpty)
        try fake.status(changing: "fol-out", [:])
        await vm.signIn("fol-out")
        #expect(fake.calls() == ["login fol-out --browser"])
    }

    @Test @MainActor func aStepButtonRunsOnlyWhileAFreshReadStillOffersIt() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.openAdd()
        vm.add?.label = "fol-out"
        vm.add?.kind = Kind.folder
        vm.add?.stage = .added
        let draft = try #require(vm.add)
        let step = try #require(vm.addSteps(draft).first { $0.id == 3 })
        #expect(step.actionEnabled)
        try fake.status(changing: "fol-out", ["linked": false])
        await vm.runStep(step)
        #expect(fake.calls().isEmpty)
        try fake.status(changing: "fol-out", [:])
        await vm.runStep(step)
        #expect(fake.calls() == ["login fol-out --browser"])
    }

    // MARK: End choice, one command from any marker state

    /// The four marker states: none, soon, a date, and both, which only a config saved before
    /// the markers became exclusive can hold.
    static var markerStates: [(name: String, fields: [String: Any])] {
        [
            ("none", ["endsAt": NSNull(), "endingSoon": false]),
            ("soon", ["endsAt": NSNull(), "endingSoon": true]),
            ("date", ["endsAt": "2026-11-20", "endingSoon": false]),
            ("both", ["endsAt": "2026-11-20", "endingSoon": true]),
        ]
    }

    @Test @MainActor func eachEndChoiceFromEachMarkerStateRunsOneCommand() async throws {
        let day = "2026-12-01"
        let choices: [(EndChoice, String)] = [
            (.never, "config set tok-ok ends none"),
            (.soon, "config set tok-ok ending-soon true"),
            (.on(day), "config set tok-ok ends \(day)"),
        ]
        for state in Self.markerStates {
            for (choice, call) in choices {
                let fake = try Fake()
                try fake.status(changing: "tok-ok", state.fields)
                let vm = Self.model(fake)
                await vm.changeEnds(label: "tok-ok", to: choice)
                #expect(fake.calls() == [call], "\(state.name) to \(choice)")
                #expect(vm.bar?.command == "agent-balancer " + call, "\(state.name) to \(choice)")
                #expect(vm.bar?.ok == true, "\(state.name) to \(choice)")
            }
        }
    }

    @Test @MainActor func aFailedEndChoiceRunsNothingMoreAndTheBarNamesIt() async throws {
        let fake = try Fake()
        try fake.status(changing: "tok-ok", ["endsAt": "2026-11-20", "endingSoon": true])
        let vm = Self.model(fake)
        try fake.failOn("config set tok-ok ending-soon true")
        await vm.changeEnds(label: "tok-ok", to: .soon)
        #expect(fake.calls() == ["config set tok-ok ending-soon true"])
        #expect(vm.bar?.ok == false)
        #expect(vm.bar?.command == "agent-balancer config set tok-ok ending-soon true")
        #expect(vm.bar?.text == "Could not save that.")
    }

    @Test @MainActor func endChoiceReadsTheStatusAgainAndRunsNothingForAGoneOrLoginAccount()
        async throws
    {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.selection = "fol-ok"
        #expect(vm.panel?.canChangeEnds == true)
        // The account was removed in Terminal after the panel was drawn.
        try fake.status(changing: "fol-ok", nil)
        await vm.changeEnds(label: "fol-ok", to: .soon)
        // Or its row now names a login account.
        try fake.status(changing: "tok-ok", ["kind": "login"])
        await vm.changeEnds(label: "tok-ok", to: .soon)
        // The login account itself, which the panel never offers an end choice for.
        await vm.changeEnds(label: "main", to: .soon)
        #expect(fake.calls().isEmpty)
    }

    // MARK: Add sheet closed while its command runs

    @MainActor static func waitUntilBusy(_ vm: ManageViewModel) async {
        for _ in 0..<10_000 {
            if vm.busy { return }
            await Task.yield()
        }
    }

    @Test @MainActor func neitherSheetClosesWhileItsCommandRuns() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.openAdd()
        vm.add?.label = "spare"
        let submit = Task { await vm.submitAdd() }
        await Self.waitUntilBusy(vm)
        #expect(vm.busy)
        // What Cancel or Esc would do, refused while `add` runs.
        vm.closeAdd()
        #expect(vm.add != nil)
        await submit.value
        #expect(vm.add?.stage == .added)
        vm.closeAdd()
        #expect(vm.add == nil)
        // The Remove sheet the same way.
        vm.selection = "tok-ok"
        vm.openRemove()
        vm.removeSheet?.typed = "tok-ok"
        let confirm = Task { await vm.confirmRemove() }
        await Self.waitUntilBusy(vm)
        #expect(vm.busy)
        vm.closeRemove()
        #expect(vm.removeSheet != nil)
        await confirm.value
        #expect(fake.calls() == ["add spare", "remove tok-ok"])
        #expect(vm.removeSheet == nil)
    }

    @Test @MainActor func aSheetReopenedWhileAddRunsKeepsTheNewEmptyForm() async throws {
        let fake = try Fake()
        let vm = Self.model(fake, settings: ManageSettings(tokenSignIn: .run))
        vm.openAdd()
        vm.add?.label = "spare"
        let submit = Task { await vm.submitAdd() }
        await Self.waitUntilBusy(vm)
        vm.closeAdd()
        vm.openAdd()
        await submit.value
        #expect(vm.add?.stage == .form)
        #expect(vm.add?.label == "")
        #expect(fake.calls() == ["add spare"])
    }

    // MARK: Sign-in time

    @Test @MainActor func signedOutShowsTheTimeTheStatusCarries() throws {
        let fake = try Fake()
        try fake.status(changing: "tok-out", ["stateSince": "2026-11-09T20:40:00Z"])
        let vm = Self.model(fake)
        vm.selection = "tok-out"
        #expect(vm.panel?.signInText == "Signed out at 12:40 PM")
        try fake.status(changing: "fol-out", ["stateSince": "2026-11-09T20:40:00Z"])
        vm.reload()
        vm.selection = "fol-out"
        #expect(vm.panel?.signInText == "Signed out since today, 12:40 PM")
        try fake.status(changing: "fol-out", ["stateSince": "2026-11-07T20:40:00Z"])
        vm.reload()
        #expect(vm.panel?.signInText == "Signed out since Nov 7, 12:40 PM")
        try fake.status(changing: "tok-out", ["stateSince": "2026-11-07T20:40:00Z"])
        vm.reload()
        vm.selection = "tok-out"
        #expect(vm.panel?.signInText == "Signed out on Nov 7 at 12:40 PM")
        // No time in the status, or one that is not a date: the plain text.
        try fake.status(changing: "tok-out", ["stateSince": "soon"])
        vm.reload()
        #expect(vm.panel?.signInText == "Signed out")
        vm.selection = "tok-ok"
        #expect(vm.panel?.signInText == "Signed in")
    }

    // MARK: Chat shell and the bar

    @Test @MainActor func inAChatShellEveryActionIsOff() async throws {
        let fake = try Fake(ambient: ["CLAUDE_CODE_CHILD_SESSION": ""])
        let vm = Self.model(fake, settings: ManageSettings(tokenSignIn: .run))
        #expect(vm.offReason != nil)
        #expect(vm.canAct == false)
        vm.selection = "tok-out"
        let panel = try #require(vm.panel)
        #expect(panel.signIn?.enabled == false)
        #expect(panel.remove?.enabled == false)
        #expect(panel.canChangeEnds == false)
        vm.openAdd()
        #expect(vm.add == nil)
        vm.openRemove()
        #expect(vm.removeSheet == nil)
        await vm.signIn("tok-out")
        await vm.changeEnds(label: "tok-out", to: .soon)
        let ok = await vm.run(.removeAccount(label: "tok-out"))
        #expect(ok == false)
        #expect(fake.calls().isEmpty)
    }

    @Test @MainActor func withoutTheChatVariableManagementIsOn() throws {
        let fake = try Fake(ambient: ["CLAUDECODE": "1"])
        let vm = Self.model(fake)
        #expect(vm.offReason == nil)
        #expect(vm.canAct)
    }

    @Test @MainActor func missingToolTurnsManagementOff() throws {
        let fake = try Fake()
        let context = fake.context
        let runner = CLIRunner(
            context: context, candidates: [fake.home.appendingPathComponent("nope")])
        let vm = ManageViewModel(context: context, runner: runner, clock: { Self.now })
        #expect(vm.offReason?.contains("not found") == true)
    }

    @Test @MainActor func barShowsTheLastCommandAndScrubbedErrorText() async throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        await vm.run(.setEndingSoon(label: "tok-ok", on: true))
        #expect(vm.bar?.command == "agent-balancer config set tok-ok ending-soon true")
        #expect(vm.bar?.ok == true)
        #expect(vm.bar?.text == "Fine: config")
        fake.failNext()
        await vm.run(.setEndingSoon(label: "tok-ok", on: false))
        #expect(vm.bar?.ok == false)
        #expect(vm.bar?.text.contains("Something went wrong") == true)
        #expect(vm.bar?.text.contains("sk-ant") == false)
    }

    @Test @MainActor func noLaunchArgumentChangesTheViewModel() throws {
        // The view model is built from the tool context only; nothing reads the process arguments.
        let fake = try Fake()
        let a = Self.model(fake)
        let b = Self.model(fake)
        #expect(a.rows == b.rows)
        #expect(a.offReason == b.offReason)
        #expect(a.settings == b.settings)
    }

    // MARK: Tips and decoding

    /// Sentences end at a period, bang or question mark followed by a space or the end, so an
    /// address like a@example.com does not split.
    static func sentenceCount(_ text: String) -> Int {
        let ends = text.ranges(of: /[.!?](\s|$)/).count
        let last = text.trimmingCharacters(in: .whitespaces).last.map { ".!?".contains($0) } ?? true
        return last ? ends : ends + 1
    }

    @Test func everyTipIsAtMostTwoSentences() {
        for tip in ManageTips.all() + ManageTips.all(email: "a@example.com", label: "x") {
            #expect(Self.sentenceCount(tip) <= 2, "\(tip)")
            #expect(tip.count <= 160, "\(tip)")
        }
        for tip in MenuTips.all { #expect(Self.sentenceCount(tip) <= 2) }
    }

    @Test func statusSnapshotDecodesTheManageFieldsAndOlderFilesStillDecode() throws {
        guard case .loaded(let snapshot) = StatusSnapshot.parse(Data(Self.accountsJson.utf8)) else {
            Issue.record("did not decode")
            return
        }
        let folder = try #require(snapshot.accounts.first { $0.label == "fol-ok" })
        #expect(folder.kind == "folder")
        #expect(folder.fullLogin == true)
        #expect(folder.linked == true)
        #expect(folder.configDir == "~/.agent-balancer/accounts/fol-ok/.claude")
        let token = try #require(snapshot.accounts.first { $0.label == "tok-ok" })
        #expect(token.loginExpiresAt != nil)
        #expect(token.loginExpiresSource == "estimate")

        let old = """
            { "schemaVersion": 1, "accounts": [ { "label": "a", "role": "pool", "state": "ok" } ] }
            """
        guard case .loaded(let s) = StatusSnapshot.parse(Data(old.utf8)) else {
            Issue.record("old file did not decode")
            return
        }
        #expect(s.accounts[0].kind == nil)
        #expect(s.accounts[0].linked == nil)
    }

    @Test @MainActor func selectOpensOnThatAccount() throws {
        let fake = try Fake()
        let vm = Self.model(fake)
        vm.select("fol-out")
        #expect(vm.selection == "fol-out")
        vm.select("nobody")
        #expect(vm.selection == "fol-out")
    }
}
