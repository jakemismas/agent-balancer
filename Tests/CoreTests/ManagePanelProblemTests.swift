import Foundation
import Testing

@testable import Core

/// The panel's problem block and the Remove sheet's account check.
extension ManageViewModelTests {
    // MARK: The reason behind "Sign-in not confirmed" and "Account ended"

    static let problemJson = """
        { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": null,
          "accounts": [
            { "label": "tok-hook", "role": "pool", "kind": "token", "state": "error",
              "error": { "code": "settings_changed",
                         "text": "Settings changed.\\u202e Run `agent-balancer link --accept-source-change`\\u0007 in Terminal." } },
            { "label": "tok-end", "role": "pool", "kind": "token", "state": "ended",
              "endsAt": "2026-11-01", "error": { "code": "account_ended", "text": "Account ended." } },
            { "label": "main", "role": "main", "kind": "login", "fullLogin": true,
              "state": "error", "error": { "code": "check_failed", "text": "Check failed: probe timed out." } },
            { "label": "fol-far", "role": "pool", "kind": "folder", "fullLogin": true,
              "linked": true, "state": "error", "signInCheck": "not_confirmed",
              "error": { "code": "check_failed",
                         "text": "Check failed: the sign-in is not in this account's own folder." } },
            { "label": "fol-doubt", "role": "pool", "kind": "folder", "fullLogin": true,
              "linked": true, "state": "ended", "endsAt": "2026-11-01", "signInCheck": "signed_in",
              "error": { "code": "account_ended", "text": "Account ended." } },
            { "label": "fol-long", "role": "pool", "kind": "folder", "fullLogin": true,
              "linked": true, "state": "error", "signInCheck": "signed_in",
              "error": { "code": "check_failed", "text": "\(String(repeating: "x", count: 900))" } },
            { "label": "fol-ok", "role": "pool", "kind": "folder", "fullLogin": true,
              "linked": true, "state": "ok", "planTier": "max_20x", "signInCheck": "signed_in" },
            { "label": "fol-out", "role": "pool", "kind": "folder", "fullLogin": true,
              "linked": true, "state": "error", "signInCheck": "signed_out",
              "error": { "code": "login_rejected", "text": "Logged out." } },
            { "label": "fol-new", "role": "pool", "kind": "folder", "fullLogin": true,
              "linked": true, "state": "ok" }
          ] }
        """

    @Test @MainActor func theNotConfirmedAndEndedPanelsGiveTheRowsOwnErrorDisplaySafe() throws {
        let fake = try Fake(statusJson: Self.problemJson)
        let vm = Self.model(fake)
        func panel(_ label: String) throws -> ManagePanel {
            vm.selection = label
            return try #require(vm.panel)
        }
        let cases: [(String, String, String, String)] = [
            ("tok-hook", "Sign-in not confirmed", "Settings changed", "settings_changed"),
            ("tok-end", "Account ended", "Account ended", "account_ended"),
            ("main", "Sign-in not confirmed", "Check failed", "check_failed"),
            ("fol-far", "Sign-in not confirmed", "Check failed", "check_failed"),
            ("fol-doubt", "Sign-in not confirmed", "Account ended", "account_ended"),
        ]
        let account = { (label: String) in vm.accounts.first { $0.label == label } }
        for (label, line, title, code) in cases {
            let shown = try panel(label)
            #expect(shown.signInText == line, "\(label)")
            let problem = try #require(shown.problem, "\(label)")
            #expect(problem.title == title, "\(label)")
            let text = try #require(account(label)?.error?.text)
            // A folder whose last check could not place its sign-in says that, not the row's text.
            let placed = account(label)?.signInCheck != SignInSeen.notConfirmed.rawValue
            let reason = placed ? MenuBuilder.plain(text) : ManageBuilder.notPlacedText
            #expect(problem.text == reason, "\(label)")
            #expect(account(label)?.error?.code == code)
            #expect(problem.steps.steps.isEmpty && problem.steps.command == nil, "\(label)")
        }
        // Control and bidi characters never reach the panel as they are.
        let hook = try #require(try panel("tok-hook").problem?.text)
        #expect(!hook.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x07 })
        #expect(!hook.contains("`"))
        // An over-long text is cut.
        let long = try #require(try panel("fol-long").problem?.text)
        #expect(long.count == 403 && long.hasSuffix("..."))
        // Signed in, signed out and not signed in have no problem block.
        for label in ["fol-ok", "fol-out", "fol-new"] {
            #expect(try panel(label).problem == nil, "\(label)")
        }
    }

    @Test @MainActor func aFolderSignInThatReportedNoEmailSaysSoInsteadOfTheFolderText() throws {
        // The status writes the check's text as it is, so the panel can tell this cause apart.
        #expect(Transitions.clean(Messages.signInEmailMissing) == Messages.signInEmailMissing)
        let json = """
            { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": null,
              "accounts": [
                { "label": "fol-mail", "role": "pool", "kind": "folder", "fullLogin": true,
                  "linked": true, "state": "error", "signInCheck": "not_confirmed",
                  "error": { "code": "check_failed", "text": "\(Messages.signInEmailMissing)" } },
                { "label": "fol-over", "role": "pool", "kind": "folder", "fullLogin": true,
                  "linked": true, "state": "error", "signInCheck": "not_confirmed",
                  "error": { "code": "settings_changed", "text": "Settings changed." } }
              ] }
            """
        let vm = Self.model(try Fake(statusJson: json))
        vm.selection = "fol-mail"
        let mail = try #require(vm.panel?.problem)
        #expect(mail.title == "Check failed")
        #expect(mail.text == ManageBuilder.noEmailText)
        #expect(mail.text.contains("reported no email"))
        // Another code over the doubt hides its cause, so the folder text stays.
        vm.selection = "fol-over"
        #expect(try #require(vm.panel?.problem).text == ManageBuilder.notPlacedText)
    }

    // MARK: The wrong_account steps

    @Test @MainActor func theWrongAccountStepsAreTheToolsOwnAndTheWindowShowsNoMenuAction() throws {
        let menu = MenuBuilder.steps(code: "wrong_account", label: "fol-wrong")
        #expect(menu.steps == [Messages.signExpectedBackIn, "Choose Refresh now."])
        #expect(menu.command == nil)
        let fake = try Fake()
        let vm = Self.model(fake)
        let wrong = try #require(vm.accounts.first { $0.label == "fol-wrong" })
        let row = MenuBuilder.row(wrong, staleAfter: 3600)
        guard case .error(let shown) = row.body else {
            Issue.record("the menu row is not an error row")
            return
        }
        #expect(shown.steps == menu)
        vm.selection = "fol-wrong"
        let problem = try #require(vm.panel?.problem)
        #expect(problem.title == "Wrong account")
        #expect(problem.steps.steps == [Messages.signExpectedBackIn])
        #expect(problem.steps.command == nil)

        // No step the window shows names an action only the menu has, for any row it reads.
        let rows = Self.folderRows + Self.otherRows
        let all = try Fake(statusJson: try Self.statusJson(rows))
        let model = Self.model(all)
        for index in rows.indices {
            model.selection = "r\(index + 1)"
            let steps = model.panel?.problem?.steps.steps ?? []
            #expect(MenuBuilder.menuOnlySteps.isDisjoint(with: steps), "r\(index + 1)")
        }
        #expect(fake.calls().isEmpty && all.calls().isEmpty)
    }

    // MARK: Remove names one account

    @Test @MainActor func removeRunsNothingWhenTheLabelNowNamesAnotherAccount() async throws {
        // The sheet opened for a folder account, then the label names a token account.
        let fake = try Fake()
        let vm = Self.model(fake)
        try Self.typedRemoveSheet(vm, "fol-ok")
        let draft = try #require(vm.removeSheet)
        #expect(draft.text == "It stops getting workers. Its folder, login and chats stay.")
        #expect(draft.kind == Kind.folder && draft.email == "fol-ok@example.com")
        try fake.status(changing: "fol-ok", ["kind": "token"])
        await vm.confirmRemove()
        #expect(fake.calls().isEmpty)
        #expect(vm.removeSheet == nil)
        #expect(vm.bar?.ok == false)
        #expect(
            vm.bar?.text == "Nothing was removed: fol-ok is another account now. Open Remove again."
        )

        // The same kind with another email, or with none, is another account too.
        for fields in [["email": "new@example.com"], ["email": NSNull()]] as [[String: Any]] {
            let other = try Fake()
            let model = Self.model(other)
            try Self.typedRemoveSheet(model, "tok-ok")
            try other.status(changing: "tok-ok", fields)
            await model.confirmRemove()
            #expect(other.calls().isEmpty, "\(fields)")
            #expect(model.removeSheet == nil, "\(fields)")
            #expect(model.bar?.text.contains("another account now") == true, "\(fields)")
        }

        // The same account, read again, is removed once.
        let same = try Fake()
        let model = Self.model(same)
        try Self.typedRemoveSheet(model, "fol-ok")
        try same.status(changing: "fol-ok", ["email": "fol-ok@example.com", "kind": "folder"])
        await model.confirmRemove()
        #expect(same.calls() == ["remove fol-ok"])
    }
}

/// Which sign-in states show a problem block, with and without a row error, in one table.
extension ManageViewModelTests {
    /// One cell of the panel's problem rule: the sign-in state a row reads as, the problem's
    /// title (nil when the panel shows none), and the row's fields.
    struct ProblemCell {
        var reads: ManageBuilder.SignIn
        var problem: String?
        var kind = Kind.folder
        var state = "ok"
        var code: String? = nil
        var linked = true
        var tier = false
        var check: String? = nil
        var ended = false
        /// False only for a pair no row reaches, so the rule alone is checked for it.
        var reachable = true
        /// A folder row as an earlier writer left it, with no `signInCheck` key.
        var earlier = false

        var errorText: String? { code.map { "The reason for \($0)." } }

        /// The problem text the panel should show: the row's own, or the not-placed text for a
        /// folder whose last check could not place the sign-in.
        var problemText: String {
            if kind == Kind.folder, check == SignInSeen.notConfirmed.rawValue {
                return ManageBuilder.notPlacedText
            }
            return MenuBuilder.plain(errorText ?? "")
        }
    }

    /// A status document with one account per cell, labelled `c1`, `c2` and on.
    static func problemStatusJson(_ cells: [ProblemCell]) throws -> String {
        var accounts: [[String: Any]] = []
        for (index, cell) in cells.enumerated() {
            let label = "c\(index + 1)"
            var fields: [String: Any] = [
                "label": label, "email": "\(label)@example.com", "role": "pool",
                "kind": cell.kind, "state": cell.state, "weekly": NSNull(),
            ]
            if cell.kind != Kind.token { fields["fullLogin"] = true }
            if cell.kind == Kind.folder { fields["linked"] = cell.linked }
            if cell.tier { fields["planTier"] = "max_20x" }
            if let code = cell.code, let text = cell.errorText {
                fields["error"] = ["code": code, "text": text]
            }
            if cell.kind == Kind.folder, !cell.earlier { fields["signInCheck"] = NSNull() }
            if let check = cell.check { fields["signInCheck"] = check }
            if cell.ended { fields["endsAt"] = "2026-11-01" }
            accounts.append(fields)
        }
        let document: [String: Any] = [
            "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": NSNull(),
            "accounts": accounts,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test @MainActor func everySignInStateWithAndWithoutARowErrorShowsTheProblemItShould() throws {
        let wrong = "Wrong account"
        let cells: [ProblemCell] = [
            // Signed in: none, whatever code the row shows over the sign-in, but an ended folder
            // keeps its sign-in line and gives its own end as the problem.
            ProblemCell(reads: .signedIn, problem: nil, tier: true),
            ProblemCell(reads: .signedIn, problem: nil, kind: Kind.token),
            ProblemCell(
                reads: .signedIn, problem: nil, state: "error", code: "settings_changed",
                tier: true),
            ProblemCell(
                reads: .signedIn, problem: "Account ended", state: "ended", code: "account_ended",
                tier: true, ended: true),
            ProblemCell(
                reads: .signedIn, problem: "Account ended", state: "ended", code: "account_ended",
                tier: true, check: "signed_in", ended: true),
            // Signed out: none. No row reads as signed out without a code.
            ProblemCell(reads: .signedOut, problem: nil, state: "error", code: "login_rejected"),
            ProblemCell(
                reads: .signedOut, problem: nil, kind: Kind.token, state: "error",
                code: "token_missing"),
            ProblemCell(reads: .signedOut, problem: nil, reachable: false),
            // Not signed in: none.
            ProblemCell(reads: .notSignedIn, problem: nil),
            ProblemCell(
                reads: .notSignedIn, problem: nil, state: "error", code: "not_linked",
                linked: false),
            ProblemCell(
                reads: .notSignedIn, problem: nil, state: "error", code: "check_failed",
                tier: true),
            ProblemCell(
                reads: .notSignedIn, problem: "Account ended", state: "ended",
                code: "account_ended", ended: true),
            // Another account: `wrong_account` with its steps, with or without a row error and
            // under any code.
            ProblemCell(
                reads: .otherAccount, problem: wrong, state: "error", code: "wrong_account"),
            ProblemCell(
                reads: .otherAccount, problem: wrong, state: "error", code: "settings_changed",
                check: "other_account"),
            ProblemCell(reads: .otherAccount, problem: wrong, check: "other_account"),
            ProblemCell(
                reads: .otherAccount, problem: wrong, kind: Kind.token, state: "error",
                code: "wrong_account"),
            ProblemCell(
                reads: .otherAccount, problem: wrong, kind: Kind.login, state: "error",
                code: "wrong_account"),
            // Ended: the row's own error, when it has one.
            ProblemCell(
                reads: .ended, problem: "Account ended", kind: Kind.token, state: "ended",
                code: "account_ended", ended: true),
            ProblemCell(
                reads: .ended, problem: "Account ended", kind: Kind.login, state: "ended",
                code: "account_ended", ended: true),
            ProblemCell(reads: .ended, problem: nil, kind: Kind.token, state: "ended"),
            // Not confirmed: the row's own error, when it has one, except a folder whose last
            // check could not place the sign-in, which says that whatever the row shows.
            ProblemCell(
                reads: .notConfirmed, problem: "Check failed", kind: Kind.token, state: "error",
                code: "check_failed"),
            ProblemCell(
                reads: .notConfirmed, problem: "Check failed", state: "error",
                code: "check_failed", check: "not_confirmed"),
            ProblemCell(
                reads: .notConfirmed, problem: "Check failed", state: "error",
                code: "settings_changed", tier: true, check: "not_confirmed"),
            ProblemCell(
                reads: .notConfirmed, problem: "Check failed", state: "ended",
                code: "account_ended", check: "not_confirmed", ended: true),
            ProblemCell(
                reads: .notConfirmed, problem: "Account ended", state: "ended",
                code: "account_ended", check: "signed_in", ended: true),
            ProblemCell(
                reads: .notConfirmed, problem: "Settings changed", kind: Kind.login,
                state: "error", code: "settings_changed"),
            ProblemCell(
                reads: .notConfirmed, problem: "Settings changed", state: "error",
                code: "settings_changed", tier: true, earlier: true),
            ProblemCell(reads: .notConfirmed, problem: "Check failed", check: "not_confirmed"),
            ProblemCell(reads: .notConfirmed, problem: nil, kind: Kind.token, state: "error"),
        ]
        // Every state is in the table, with and without a row error.
        let states: [ManageBuilder.SignIn] = [
            .signedIn, .signedOut, .notSignedIn, .otherAccount, .ended, .notConfirmed,
        ]
        for state in states {
            for withError in [false, true] {
                #expect(
                    cells.contains { $0.reads == state && ($0.code != nil) == withError },
                    "\(state) \(withError ? "with" : "without") a row error")
            }
        }

        let fake = try Fake(statusJson: try Self.problemStatusJson(cells))
        let vm = Self.model(fake)
        #expect(vm.accounts.count == cells.count)
        for (index, cell) in cells.enumerated() {
            let label = "c\(index + 1)"
            let name = "\(label) \(cell.reads) \(cell.kind) \(cell.state) \(cell.code ?? "no code")"
            let account = try #require(vm.accounts.first { $0.label == label }, "\(name)")
            // The rule, from the state and the row.
            #expect(
                ManageBuilder.problem(account, state: cell.reads)?.title == cell.problem, "\(name)")
            let state = ManageBuilder.signInState(account)
            guard cell.reachable else {
                #expect(state != cell.reads, "\(name)")
                continue
            }
            // The panel reads the row as that state and shows what the rule says.
            #expect(state == cell.reads, "\(name): reads \(state)")
            vm.selection = label
            let panel = try #require(vm.panel, "\(name)")
            #expect(panel.problem?.title == cell.problem, "\(name)")
            guard let problem = panel.problem else { continue }
            if cell.reads == .otherAccount {
                let own = cell.code == "wrong_account" ? cell.errorText : nil
                #expect(problem.text == MenuBuilder.plain(own ?? Messages.wrongAccount), "\(name)")
                #expect(problem.steps.steps == [Messages.signExpectedBackIn], "\(name)")
            } else {
                #expect(problem.text == cell.problemText, "\(name)")
                #expect(problem.steps.steps.isEmpty && problem.steps.command == nil, "\(name)")
            }
        }
        #expect(fake.calls().isEmpty)
    }
}
