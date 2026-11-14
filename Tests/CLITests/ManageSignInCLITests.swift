import Core
import Foundation
import Testing

@testable import Core

/// The window's own Sign in on a folder account, run through the real tool against the fake
/// `claude`: what the bar says, and what the window reads afterwards.
extension FolderAccountsCLITests {
    @MainActor func window(_ cli: CLIHome) -> ManageViewModel {
        let ctx = context(cli)
        let vm = ManageViewModel(
            context: ctx, runner: CLIRunner(context: ctx, candidates: [cli.exe]))
        vm.windowOpened()
        vm.selection = "spare"
        return vm
    }

    /// The window reads `spare` as signed in to another account: red in the list and the panel,
    /// the `wrong_account` problem with the tool's own step, no Sign in, and step 3 not done.
    @MainActor func expectAnotherAccount(
        _ vm: ManageViewModel, end: String = "", ended: Bool = false
    ) throws {
        vm.selection = "spare"
        let panel = try #require(vm.panel)
        #expect(panel.signInText == "Signed in as another account" && !panel.signedIn)
        #expect(panel.signIn == nil)
        #expect(panel.problem?.title == "Wrong account")
        #expect(panel.problem?.steps.steps == [Messages.signExpectedBackIn])
        #expect(panel.emailLine == Self.email)
        let list = try #require(vm.rows.first { $0.label == "spare" })
        #expect(list.subtitle == "Signed in as another account" + end && !list.signedIn)
        #expect(
            list.accessibilityLabel
                == "spare, folder account, signed in as another account" + (ended ? ", ended" : ""))
        var draft = AddDraft()
        draft.label = "spare"
        draft.kind = Kind.folder
        draft.stage = .added
        let step = try #require(vm.addSteps(draft).first { $0.id == 3 })
        #expect(step.state == .todo && !step.actionEnabled)
    }

    @Test @MainActor func aWindowSignInOnAnotherAccountDuringAHookChangeReadsAsAnotherAccount()
        async throws
    {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try signedIn(cli, loggedIn: false)
        #expect(try cli.run(["status", "--json"]).status == 0)
        try cli.settings(#"{"hooks":{}}"#)
        _ = try cli.run(["pick", "--json"])
        let vm = window(cli)
        #expect(vm.panel?.signInText.hasPrefix("Signed out") == true)
        #expect(vm.panel?.signIn?.title == "Sign in again..." && vm.panel?.signIn?.enabled == true)

        try cli.fake(
            "auth-after-sign-in.json", try authJSON(cli, loggedIn: true, email: "other@example.com")
        )
        await vm.signIn("spare")
        #expect(cli.fakeRecord("args.log").contains("auth login --email \(Self.email)"))
        let bar = try #require(vm.bar)
        #expect(!bar.ok && bar.text.hasPrefix("Error wrong_account:"), "\(bar.text)")
        let row = try statusRow(cli)
        #expect((row["error"] as? [String: Any])?["code"] as? String == "settings_changed")
        #expect(row["planTier"] is NSNull && row["signInCheck"] as? String == "other_account")
        try expectAnotherAccount(vm)
    }

    @Test @MainActor func aWindowSignInOnAnEndedFolderThatEndsOnAnotherAccountReadsSo()
        async throws
    {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try signedIn(cli, loggedIn: false)
        let store = ConfigStore(context: context(cli))
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "spare" })
        config.accounts[index].endsAt = "2026-01-01"
        try store.save(config)
        #expect(try cli.run(["status", "--json"]).status == 0)
        let vm = window(cli)
        #expect(vm.panel?.signInText == "Not signed in")
        #expect(
            vm.rows.first { $0.label == "spare" }?.subtitle == "Not signed in \u{00B7} ended Jan 1")
        #expect(vm.panel?.problem?.title == "Account ended")

        try cli.fake(
            "auth-after-sign-in.json", try authJSON(cli, loggedIn: true, email: "other@example.com")
        )
        await vm.signIn("spare")
        let bar = try #require(vm.bar)
        #expect(!bar.ok && bar.text.hasPrefix("Error wrong_account:"), "\(bar.text)")
        let row = try statusRow(cli)
        #expect((row["error"] as? [String: Any])?["code"] as? String == "account_ended")
        #expect(row["planTier"] is NSNull && row["signInCheck"] as? String == "other_account")
        try expectAnotherAccount(vm, end: " \u{00B7} ended Jan 1", ended: true)
    }

    @Test @MainActor func theBrowserSignInBarShowsTheResultOrTheErrorLineNeverTheAdvice()
        async throws
    {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try signedIn(cli, loggedIn: false)
        #expect(try cli.run(["status", "--json"]).status == 0)
        let vm = window(cli)

        // Cancelled in the browser: still signed out afterwards.
        await vm.signIn("spare")
        var bar = try #require(vm.bar)
        #expect(!bar.ok && bar.text.hasPrefix("Error login_rejected:"), "\(bar.text)")
        #expect(bar.command == "agent-balancer login spare --browser")

        // Another account.
        try cli.fake(
            "auth-after-sign-in.json", try authJSON(cli, loggedIn: true, email: "other@example.com")
        )
        await vm.signIn("spare")
        bar = try #require(vm.bar)
        #expect(!bar.ok && bar.text.hasPrefix("Error wrong_account:"), "\(bar.text)")
        try expectAnotherAccount(vm)

        // The expected account, after the other one is signed out.
        try signedIn(cli, loggedIn: false)
        try cli.fake("auth-after-sign-in.json", try authJSON(cli, loggedIn: true))
        #expect(try cli.run(["status", "--json"]).status == 0)
        await vm.signIn("spare")
        bar = try #require(vm.bar)
        #expect(bar.ok && bar.text == "Signed in. The folder holds the expected account.")
        vm.selection = "spare"
        #expect(vm.panel?.signInText == "Signed in" && vm.panel?.signedIn == true)
    }

    @Test @MainActor func aSignInMadeOutsideTheWindowIsRecordedWhenItsSignInIsRefused()
        async throws
    {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        try signedIn(cli, loggedIn: false)
        #expect(try cli.run(["status", "--json"]).status == 0)
        // Signed in again in Terminal, and a probe that works since.
        try signedIn(cli, loggedIn: true)
        #expect(try cli.run(["refresh", "--label", "spare", "--force"]).status == 0)
        var row = try statusRow(cli)
        #expect(row["error"] is NSNull && row["planTier"] is NSNull)
        let vm = window(cli)
        #expect(vm.panel?.signInText == "Not signed in")
        #expect(vm.panel?.signIn?.enabled == true)

        await vm.signIn("spare")
        let bar = try #require(vm.bar)
        #expect(!bar.ok && bar.text.contains("is already signed in"), "\(bar.text)")
        #expect(!cli.fakeRecord("args.log").contains("auth login"))
        row = try statusRow(cli)
        #expect(row["planTier"] as? String == "max_20x")
        #expect(row["signInCheck"] as? String == "signed_in")
        vm.selection = "spare"
        #expect(vm.panel?.signInText == "Signed in" && vm.panel?.signedIn == true)
        #expect(vm.panel?.signIn == nil)

        // The same refusal with another account signed in records that, and keeps no tier.
        try cli.fake(
            "auth.json", try authJSON(cli, loggedIn: true, email: "other@example.com"))
        let refused = try cli.run(["login", "spare", "--browser"])
        #expect(refused.status == 1)
        row = try statusRow(cli)
        #expect(row["planTier"] is NSNull && row["signInCheck"] as? String == "other_account")
        vm.statusMayHaveChanged()
        try expectAnotherAccount(vm)
    }

    @Test @MainActor func anAlreadySignedInCheckThatCannotPlaceTheSignInKeepsNoTier() throws {
        let cli = try setUp()
        defer { cli.cleanup() }
        try linked(cli)
        // Placed by a check first, so the row holds the tier.
        #expect(try cli.run(["status", "--json"]).status == 0)
        var row = try statusRow(cli)
        #expect(row["planTier"] as? String == "max_20x")
        #expect(row["signInCheck"] as? String == "signed_in")
        // The expected account, signed in in the default folder, then with no folder reported.
        let elsewhere = cli.home.appendingPathComponent(".claude").path
        for folder in [#","configDirectory":"\#(elsewhere)""#, ""] {
            try cli.fake(
                "auth.json",
                #"{"loggedIn":true,"email":"\#(Self.email)","planTier":"max_20x"\#(folder)}"#)
            let refused = try cli.run(["login", "spare", "--browser"])
            let said = String(decoding: refused.stderr, as: UTF8.self)
            #expect(refused.status == 1 && said.contains("already signed in"))
            row = try statusRow(cli)
            #expect(row["signInCheck"] as? String == "not_confirmed", "\(folder)")
            #expect(row["planTier"] is NSNull, "\(folder)")
            #expect((row["error"] as? [String: Any])?["code"] as? String == "check_failed")
        }
        #expect(!cli.fakeRecord("args.log").contains("auth login"))
        // The window reads it as not confirmed, says why, and offers no Sign in.
        let vm = window(cli)
        let panel = try #require(vm.panel)
        #expect(panel.signInText == "Sign-in not confirmed" && !panel.signedIn)
        #expect(panel.signIn == nil)
        #expect(panel.problem?.text == ManageBuilder.notPlacedText)
    }

    @Test func theWindowAndLoginShareOnePlainEmailRule() throws {
        // The window offers Sign in by the same rule `login --browser` refuses by.
        let sources = Support.root.appendingPathComponent("Sources")
        var homes: [String] = []
        let walker = FileManager.default.enumerator(atPath: sources.path)
        while let path = walker?.nextObject() as? String {
            guard path.hasSuffix(".swift") else { continue }
            let text = try String(
                contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            if text.contains("func isPlainEmail") { homes.append(path) }
        }
        #expect(homes == ["Core/Config/ConfigValidator.swift"])
        let login = try String(
            contentsOf: sources.appendingPathComponent("agent-balancer/Commands/Login.swift"),
            encoding: .utf8)
        #expect(login.contains("ConfigValidator.isPlainEmail(email)"))
        #expect(login.contains("Messages.emailNotPlain(label)"))
    }
}
