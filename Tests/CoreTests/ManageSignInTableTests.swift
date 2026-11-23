import Foundation
import Testing

@testable import Core

/// Every row the tool writes shows one sign-in state that the list and the panel agree on, and a
/// folder reads as signed in only on evidence: a check that placed the sign-in in the folder and
/// nothing since that says otherwise. A token or login account, which has no such evidence, reads
/// as signed in only while its row has no code.
extension ManageViewModelTests {
    /// What the window shows for one account.
    struct Shown: Equatable, CustomStringConvertible {
        var panel: String
        var panelGreen: Bool
        var list: String
        var listGreen: Bool
        /// The state words the list row speaks to VoiceOver.
        var spoken: String
        /// The panel's Sign in control: its title, or nil when there is none, and whether it is on.
        var signIn: String?
        var signInOn: Bool
        /// The Add sheet's sign-in step (3 for a folder, 2 for a token), or nil for a login.
        var stepDone: Bool?
        var stepOn: Bool?

        var description: String {
            "\(panel) green \(panelGreen) | \(list) green \(listGreen) | \(spoken) | "
                + "\(signIn ?? "no sign in") on \(signInOn) | step done "
                + "\(stepDone.map(String.init) ?? "none") on \(stepOn.map(String.init) ?? "none")"
        }

        static func folderIn(_ end: String = "") -> Shown {
            Shown(
                panel: "Signed in", panelGreen: true, list: "Signed in" + end, listGreen: true,
                spoken: "signed in", signIn: nil, signInOn: false, stepDone: true, stepOn: false)
        }

        static func folderNot(linked: Bool, _ end: String = "") -> Shown {
            Shown(
                panel: "Not signed in", panelGreen: false, list: "Not signed in" + end,
                listGreen: false, spoken: "not signed in", signIn: "Sign in...", signInOn: linked,
                stepDone: false, stepOn: linked)
        }

        static func folderOut(linked: Bool) -> Shown {
            Shown(
                panel: "Signed out", panelGreen: false, list: "Signed out", listGreen: false,
                spoken: "signed out", signIn: "Sign in again...", signInOn: linked,
                stepDone: false, stepOn: linked)
        }

        static let folderOther = Shown(
            panel: "Signed in as another account", panelGreen: false,
            list: "Signed in as another account", listGreen: false,
            spoken: "signed in as another account", signIn: nil, signInOn: false,
            stepDone: false, stepOn: false)

        static func folderNotConfirmed(_ end: String = "") -> Shown {
            Shown(
                panel: "Sign-in not confirmed", panelGreen: false,
                list: "Sign-in not confirmed" + end, listGreen: false,
                spoken: "sign-in not confirmed", signIn: nil, signInOn: false, stepDone: false,
                stepOn: false)
        }

        static func tokenIn(_ list: String = "Signed in") -> Shown {
            Shown(
                panel: "Signed in", panelGreen: true, list: list, listGreen: true,
                spoken: "signed in", signIn: "Sign in again...", signInOn: true, stepDone: true,
                stepOn: false)
        }

        static let tokenOut = Shown(
            panel: "Signed out", panelGreen: false, list: "Signed out", listGreen: false,
            spoken: "signed out", signIn: "Sign in again...", signInOn: true, stepDone: false,
            stepOn: true)

        static let tokenOther = Shown(
            panel: "Signed in as another account", panelGreen: false,
            list: "Signed in as another account", listGreen: false,
            spoken: "signed in as another account", signIn: "Sign in again...", signInOn: true,
            stepDone: false, stepOn: true)

        /// An ended token row, whose list line is its end.
        static func tokenEnded(_ list: String) -> Shown {
            Shown(
                panel: "Account ended", panelGreen: false, list: list,
                listGreen: false, spoken: "account ended", signIn: "Sign in again...",
                signInOn: true, stepDone: false, stepOn: true)
        }

        static let tokenNotConfirmed = Shown(
            panel: "Sign-in not confirmed", panelGreen: false, list: "Sign-in not confirmed",
            listGreen: false, spoken: "sign-in not confirmed", signIn: "Sign in again...",
            signInOn: true, stepDone: false, stepOn: true)

        static func loginIn(_ list: String = "Your login") -> Shown {
            Shown(
                panel: "Signed in with your own login", panelGreen: true, list: list,
                listGreen: true, spoken: "signed in", signIn: nil, signInOn: false, stepDone: nil,
                stepOn: nil)
        }

        static let loginOut = Shown(
            panel: "Signed out", panelGreen: false, list: "Signed out", listGreen: false,
            spoken: "signed out", signIn: nil, signInOn: false, stepDone: nil, stepOn: nil)

        static let loginOther = Shown(
            panel: "Signed in as another account", panelGreen: false,
            list: "Signed in as another account", listGreen: false,
            spoken: "signed in as another account", signIn: nil, signInOn: false, stepDone: nil,
            stepOn: nil)

        /// An ended login row, whose list line is its end.
        static func loginEnded(_ list: String) -> Shown {
            Shown(
                panel: "Account ended", panelGreen: false, list: list,
                listGreen: false, spoken: "account ended", signIn: nil, signInOn: false,
                stepDone: nil, stepOn: nil)
        }

        /// The same for a folder whose row has ended: the list and VoiceOver say so.
        func ended(_ end: String) -> Shown {
            var shown = self
            shown.list += end
            shown.spoken += ", ended"
            return shown
        }

        static let loginNotConfirmed = Shown(
            panel: "Sign-in not confirmed", panelGreen: false, list: "Sign-in not confirmed",
            listGreen: false, spoken: "sign-in not confirmed", signIn: nil, signInOn: false,
            stepDone: nil, stepOn: nil)
    }

    /// One status row: its kind, state, error code, link, plan tier and other fields. A folder
    /// row carries `signInCheck` (null unless `extra` sets it), as this version writes it, unless
    /// it has the shape an earlier writer gave it, with no such key.
    struct SignInRow {
        var kind: String
        var state: String
        var code: String?
        var linked: Bool? = nil
        var tier: String? = nil
        var extra: [String: any Sendable] = [:]
        var earlier = false
        var shown: Shown
    }

    static let ended: [String: any Sendable] = ["endsAt": "2026-11-01"]
    static let endedByPlan: [String: any Sendable] = ["endingSoon": true]
    static let tier = "max_20x"

    /// Every state and error code the tool writes for a folder, with and without the plan tier
    /// and the link, then a few shapes it never writes, which must fail closed too.
    static let folderRows: [SignInRow] = [
        SignInRow(kind: "folder", state: "ok", linked: true, tier: tier, shown: .folderIn()),
        // Linked, and no check has seen it signed in yet.
        SignInRow(kind: "folder", state: "ok", linked: true, shown: .folderNot(linked: true)),
        SignInRow(kind: "folder", state: "limited", linked: true, tier: tier, shown: .folderIn()),
        SignInRow(kind: "folder", state: "limited", linked: true, shown: .folderNot(linked: true)),
        SignInRow(
            kind: "folder", state: "error", code: "login_rejected", linked: true, tier: tier,
            shown: .folderOut(linked: true)),
        SignInRow(
            kind: "folder", state: "error", code: "login_rejected", linked: true,
            shown: .folderOut(linked: true)),
        // A signed-out folder that is not linked either: `login_rejected` hides `not_linked`.
        SignInRow(
            kind: "folder", state: "error", code: "login_rejected", linked: false,
            shown: .folderOut(linked: false)),
        // A hook record that changed, with the link itself sound.
        SignInRow(
            kind: "folder", state: "error", code: "settings_changed", linked: true, tier: tier,
            shown: .folderIn()),
        SignInRow(
            kind: "folder", state: "error", code: "settings_changed", linked: true,
            shown: .folderNot(linked: true)),
        // A broken link: the folder is not linked, whatever its tier.
        SignInRow(
            kind: "folder", state: "error", code: "settings_changed", linked: false, tier: tier,
            shown: .folderNot(linked: false)),
        SignInRow(
            kind: "folder", state: "error", code: "not_linked", linked: false,
            shown: .folderNot(linked: false)),
        SignInRow(
            kind: "folder", state: "error", code: "not_linked", linked: false, tier: tier,
            shown: .folderNot(linked: false)),
        SignInRow(
            kind: "folder", state: "error", code: "wrong_account", linked: true, tier: tier,
            shown: .folderOther),
        SignInRow(
            kind: "folder", state: "error", code: "wrong_account", linked: true,
            shown: .folderOther),
        SignInRow(
            kind: "folder", state: "error", code: "duplicate_login", linked: true, tier: tier,
            shown: .folderIn()),
        SignInRow(
            kind: "folder", state: "error", code: "duplicate_login", linked: true,
            shown: .folderNot(linked: true)),
        SignInRow(
            kind: "folder", state: "error", code: "plan_changed", linked: true, tier: tier,
            shown: .folderIn()),
        SignInRow(
            kind: "folder", state: "error", code: "plan_changed", linked: true,
            shown: .folderNot(linked: true)),
        // A check the tool judged failed: the sign-in is in another folder, its folder is not
        // reported, or the check or the probe did not run.
        SignInRow(
            kind: "folder", state: "error", code: "check_failed", linked: true, tier: tier,
            shown: .folderNot(linked: true)),
        SignInRow(
            kind: "folder", state: "error", code: "check_failed", linked: true,
            shown: .folderNot(linked: true)),
        // `account_ended` hides every other code, so only the tier tells. The end says it has
        // ended, and the sign-in line stays as the tier reads.
        SignInRow(
            kind: "folder", state: "ended", code: "account_ended", linked: true, tier: tier,
            extra: ended, shown: .folderIn().ended(" \u{00B7} ended Nov 1")),
        SignInRow(
            kind: "folder", state: "ended", code: "account_ended", linked: true, extra: ended,
            shown: .folderNot(linked: true).ended(" \u{00B7} ended Nov 1")),
        SignInRow(
            kind: "folder", state: "ended", code: "account_ended", linked: false, tier: tier,
            extra: ended, shown: .folderNot(linked: false).ended(" \u{00B7} ended Nov 1")),
        SignInRow(
            kind: "folder", state: "ended", code: "account_ended", linked: true, tier: tier,
            extra: endedByPlan, shown: .folderIn().ended(" \u{00B7} ended")),
        // Shapes the tool never writes for a folder.
        SignInRow(
            kind: "folder", state: "error", code: "token_missing", linked: true, tier: tier,
            shown: .folderOut(linked: true)),
        SignInRow(
            kind: "folder", state: "error", code: "a_later_code", linked: true, tier: tier,
            shown: .folderNot(linked: true)),
        SignInRow(
            kind: "folder", state: "error", linked: true, tier: tier,
            shown: .folderNot(linked: true)),
        SignInRow(
            kind: "folder", state: "ok", code: "plan_changed", linked: true, tier: tier,
            shown: .folderNot(linked: true)),
        SignInRow(kind: "folder", state: "ok", tier: tier, shown: .folderNot(linked: false)),
        // The last sign-in check's result, which the row's one code can hide, comes first.
        SignInRow(
            kind: "folder", state: "ok", linked: true, tier: tier,
            extra: ["signInCheck": "signed_in"], shown: .folderIn()),
        SignInRow(
            kind: "folder", state: "error", code: "settings_changed", linked: true,
            extra: ["signInCheck": "other_account"], shown: .folderOther),
        SignInRow(
            kind: "folder", state: "ended", code: "account_ended", linked: true,
            extra: ["signInCheck": "other_account", "endsAt": "2026-11-01"],
            shown: Shown.folderOther.ended(" \u{00B7} ended Nov 1")),
        SignInRow(
            kind: "folder", state: "error", code: "login_rejected", linked: true,
            extra: ["signInCheck": "other_account"], shown: .folderOther),
        SignInRow(
            kind: "folder", state: "error", code: "not_linked", linked: false,
            extra: ["signInCheck": "other_account"], shown: .folderOther),
        // Signed in somewhere the check could not place: `login --browser` would refuse it.
        SignInRow(
            kind: "folder", state: "error", code: "check_failed", linked: true,
            extra: ["signInCheck": "not_confirmed"], shown: .folderNotConfirmed()),
        SignInRow(
            kind: "folder", state: "error", code: "settings_changed", linked: true, tier: tier,
            extra: ["signInCheck": "not_confirmed"], shown: .folderNotConfirmed()),
        // Placed by the last check, with a doubt since that leaves the tier out.
        SignInRow(
            kind: "folder", state: "error", code: "check_failed", linked: true,
            extra: ["signInCheck": "signed_in"], shown: .folderNotConfirmed()),
        SignInRow(
            kind: "folder", state: "ended", code: "account_ended", linked: true,
            extra: ["signInCheck": "signed_in", "endsAt": "2026-11-01"],
            shown: .folderNotConfirmed().ended(" \u{00B7} ended Nov 1")),
        SignInRow(
            kind: "folder", state: "error", code: "login_rejected", linked: true,
            extra: ["signInCheck": "signed_in"], shown: .folderOut(linked: true)),
        SignInRow(
            kind: "folder", state: "error", code: "check_failed", linked: false,
            extra: ["signInCheck": "signed_in"], shown: .folderNot(linked: false)),
        // Seen signed out last: a tier never counts then, and Sign in is offered.
        SignInRow(
            kind: "folder", state: "ok", linked: true, tier: tier,
            extra: ["signInCheck": "signed_out"], shown: .folderNot(linked: true)),
        SignInRow(
            kind: "folder", state: "ended", code: "account_ended", linked: true,
            extra: ["signInCheck": "signed_out", "endsAt": "2026-11-01"],
            shown: .folderNot(linked: true).ended(" \u{00B7} ended Nov 1")),
        // A result this version does not know fails closed.
        SignInRow(
            kind: "folder", state: "ok", linked: true, tier: tier,
            extra: ["signInCheck": "a_later_result"], shown: .folderNotConfirmed()),
        // An earlier writer kept the tier through a doubt and wrote no `signInCheck`, so a code
        // that can hide a doubt leaves the sign-in unconfirmed, with no Sign in.
        SignInRow(
            kind: "folder", state: "ok", linked: true, tier: tier, earlier: true,
            shown: .folderIn()),
        SignInRow(
            kind: "folder", state: "error", code: "settings_changed", linked: true, tier: tier,
            earlier: true, shown: .folderNotConfirmed()),
        SignInRow(
            kind: "folder", state: "error", code: "settings_changed", linked: true,
            earlier: true, shown: .folderNotConfirmed()),
        // Not linked, it shows its link step with Sign in off, whatever its code.
        SignInRow(
            kind: "folder", state: "error", code: "not_linked", linked: false, tier: tier,
            earlier: true, shown: .folderNot(linked: false)),
        SignInRow(
            kind: "folder", state: "error", code: "check_failed", linked: false, tier: tier,
            earlier: true, shown: .folderNot(linked: false)),
        SignInRow(
            kind: "folder", state: "error", code: "duplicate_login", linked: true, tier: tier,
            earlier: true, shown: .folderNotConfirmed()),
        SignInRow(
            kind: "folder", state: "error", code: "plan_changed", linked: true, tier: tier,
            earlier: true, shown: .folderNotConfirmed()),
        SignInRow(
            kind: "folder", state: "ended", code: "account_ended", linked: true, tier: tier,
            extra: ended, earlier: true,
            shown: .folderNotConfirmed().ended(" \u{00B7} ended Nov 1")),
        SignInRow(
            kind: "folder", state: "ended", code: "account_ended", linked: true, tier: tier,
            extra: endedByPlan, earlier: true, shown: .folderNotConfirmed().ended(" \u{00B7} ended")
        ),
        // A code that is the doubt itself reads as it does in any status.
        SignInRow(
            kind: "folder", state: "error", code: "login_rejected", linked: true, tier: tier,
            earlier: true, shown: .folderOut(linked: true)),
        SignInRow(
            kind: "folder", state: "error", code: "wrong_account", linked: true, tier: tier,
            earlier: true, shown: .folderOther),
        // Such a writer's check may have failed over a sign-in it saw, so no Sign in.
        SignInRow(
            kind: "folder", state: "error", code: "check_failed", linked: true, tier: tier,
            earlier: true, shown: .folderNotConfirmed()),
        SignInRow(
            kind: "folder", state: "error", code: "check_failed", linked: true, earlier: true,
            shown: .folderNotConfirmed()),
    ]

    /// The token and login rows the window shows. Neither kind reads the tier, so only a row with
    /// no code reads as signed in: any code could hide a check that saw it signed out or could not
    /// confirm it, and `account_ended` hides them all.
    static let otherRows: [SignInRow] = [
        SignInRow(kind: "token", state: "ok", shown: .tokenIn()),
        SignInRow(kind: "token", state: "limited", shown: .tokenIn()),
        SignInRow(kind: "token", state: "error", code: "token_missing", shown: .tokenOut),
        SignInRow(kind: "token", state: "error", code: "login_rejected", shown: .tokenOut),
        SignInRow(
            kind: "token", state: "error", code: "settings_changed", shown: .tokenNotConfirmed),
        SignInRow(kind: "token", state: "error", code: "check_failed", shown: .tokenNotConfirmed),
        SignInRow(
            kind: "token", state: "ended", code: "account_ended", extra: ended,
            shown: .tokenEnded("Ended Nov 1")),
        SignInRow(kind: "token", state: "error", code: "wrong_account", shown: .tokenOther),
        SignInRow(
            kind: "token", state: "error", code: "duplicate_login", shown: .tokenNotConfirmed),
        SignInRow(kind: "login", state: "ok", tier: tier, shown: .loginIn()),
        SignInRow(kind: "login", state: "limited", tier: tier, shown: .loginIn()),
        SignInRow(kind: "login", state: "error", code: "login_rejected", shown: .loginOut),
        SignInRow(
            kind: "login", state: "error", code: "wrong_account", tier: tier, shown: .loginOther),
        // A login row's tier counts under these two codes, as a folder row's does.
        SignInRow(
            kind: "login", state: "error", code: "plan_changed", tier: tier, shown: .loginIn()),
        SignInRow(
            kind: "login", state: "error", code: "duplicate_login", tier: tier, shown: .loginIn()),
        SignInRow(kind: "login", state: "error", code: "plan_changed", shown: .loginNotConfirmed),
        SignInRow(
            kind: "login", state: "error", code: "duplicate_login", shown: .loginNotConfirmed),
        SignInRow(
            kind: "login", state: "error", code: "settings_changed", tier: tier,
            shown: .loginNotConfirmed),
        SignInRow(kind: "login", state: "error", code: "check_failed", shown: .loginNotConfirmed),
        SignInRow(
            kind: "login", state: "ended", code: "account_ended", tier: tier, extra: ended,
            shown: .loginEnded("Ended Nov 1")),
        // Ended by its plan, with no date that has passed.
        SignInRow(
            kind: "login", state: "ended", code: "account_ended", tier: tier,
            extra: endedByPlan, shown: .loginEnded("Ended")),
        // Shapes the tool never writes for a token or login account.
        SignInRow(kind: "token", state: "error", shown: .tokenNotConfirmed),
        SignInRow(kind: "token", state: "error", code: "a_later_code", shown: .tokenNotConfirmed),
        SignInRow(
            kind: "login", state: "ok", code: "plan_changed", tier: tier,
            shown: .loginNotConfirmed),
    ]

    /// A status document with one account per row, labelled `r1`, `r2` and on.
    static func statusJson(_ rows: [SignInRow]) throws -> String {
        var accounts: [[String: Any]] = []
        for (index, row) in rows.enumerated() {
            let label = "r\(index + 1)"
            var fields: [String: Any] = [
                "label": label, "email": "\(label)@example.com", "role": "pool",
                "kind": row.kind, "state": row.state, "weekly": NSNull(),
            ]
            if row.kind != Kind.token { fields["fullLogin"] = true }
            if row.kind == Kind.folder, !row.earlier { fields["signInCheck"] = NSNull() }
            if let linked = row.linked { fields["linked"] = linked }
            if let tier = row.tier { fields["planTier"] = tier }
            if let code = row.code { fields["error"] = ["code": code, "text": "Text."] }
            for (key, value) in row.extra { fields[key] = value }
            accounts.append(fields)
        }
        let document: [String: Any] = [
            "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": NSNull(),
            "accounts": accounts,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// What the open window shows for `label` now.
    @MainActor static func shown(_ vm: ManageViewModel, _ label: String, kind: String) throws
        -> Shown
    {
        vm.selection = label
        let panel = try #require(vm.panel)
        let row = try #require(vm.rows.first { $0.label == label })
        let prefix = "\(label), \(kind) account, "
        let spoken =
            row.accessibilityLabel.hasPrefix(prefix)
            ? String(row.accessibilityLabel.dropFirst(prefix.count))
            : "<\(row.accessibilityLabel)>"
        var step: AddStep?
        if kind != Kind.login {
            var draft = AddDraft()
            draft.label = label
            draft.kind = kind
            draft.stage = .added
            step = vm.addSteps(draft).first { $0.id == (kind == Kind.token ? 2 : 3) }
        }
        return Shown(
            panel: panel.signInText, panelGreen: panel.signedIn, list: row.subtitle,
            listGreen: row.signedIn, spoken: spoken, signIn: panel.signIn?.title,
            signInOn: panel.signIn?.enabled ?? false, stepDone: step.map { $0.state == .done },
            stepOn: step?.actionEnabled)
    }

    @Test @MainActor func everyRowTheToolWritesShowsOneSignInStateThatFailsClosed() async throws {
        let rows = Self.folderRows + Self.otherRows
        // Every error code a row can carry has a folder row, so a new code needs one too.
        let neverAnError: Set<StateCode> = [
            .limited, .fableLimited, .loginExpiring, .possibleDuplicate, .keyInSettings, .stale,
            .launchFileMissing, .launchFileUnchecked,
        ]
        let folderCodes = Set(Self.folderRows.compactMap(\.code))
        for code in StateCode.allCases where !neverAnError.contains(code) {
            #expect(folderCodes.contains(code.rawValue), "no folder row for \(code.rawValue)")
        }
        #expect(Set(Self.folderRows.map(\.state)) == ["ok", "limited", "error", "ended"])

        let fake = try Fake(statusJson: try Self.statusJson(rows))
        let vm = Self.model(fake)
        vm.windowOpened()
        #expect(vm.accounts.count == rows.count)
        var offered: [String] = []
        for (index, row) in rows.enumerated() {
            let label = "r\(index + 1)"
            let name =
                "\(label) \(row.kind) \(row.state) \(row.code ?? "no code") linked "
                + "\(row.linked.map(String.init) ?? "none") tier \(row.tier ?? "none")"
                + (row.earlier ? " earlier shape" : "")
            let seen = try Self.shown(vm, label, kind: row.kind)
            #expect(seen == row.shown, "\(name): \(seen)")
            // The list's dot and the panel's dot always agree.
            #expect(seen.listGreen == seen.panelGreen, "\(name)")
            if row.kind == Kind.folder, row.shown.signIn != nil, row.shown.signInOn {
                offered.append("login \(label) --browser")
            }
        }
        // The Sign in button runs only where the panel offers it, from a fresh read.
        for (index, row) in rows.enumerated() where row.kind == Kind.folder {
            await vm.signIn("r\(index + 1)")
        }
        #expect(fake.calls() == offered)
        #expect(!offered.isEmpty)
    }
}

/// The plan tier in the status file counts as a folder's sign-in only while the last sign-in
/// check placed the sign-in in the folder and no check since says it is gone or unconfirmed, so
/// a code the row hides cannot turn the window green.
extension ManageViewModelTests {
    enum Seen: Equatable {
        case signedIn, notSignedIn, signedOut, otherAccount, notConfirmed
    }

    @MainActor static func seen(_ vm: ManageViewModel, _ label: String) throws -> Seen {
        let shown = try Self.shown(vm, label, kind: Kind.folder)
        #expect(shown.panelGreen == shown.listGreen)
        switch shown.panel {
        case "Signed in":
            #expect(shown.stepDone == true && shown.signIn == nil)
            return .signedIn
        case "Not signed in":
            #expect(shown.stepDone == false && shown.signIn == "Sign in...")
            return .notSignedIn
        case "Signed in as another account":
            #expect(shown.stepDone == false && shown.signIn == nil)
            return .otherAccount
        case "Sign-in not confirmed":
            #expect(!shown.panelGreen && shown.stepDone == false && shown.stepOn == false)
            #expect(shown.signIn == nil)
            return .notConfirmed
        default:
            #expect(shown.panel.hasPrefix("Signed out"), "\(shown)")
            #expect(shown.stepDone == false && shown.signIn == "Sign in again...")
            return .signedOut
        }
    }

    @Test @MainActor func aFolderReadsSignedInOnlyWhileTheLastCheckPlacedItThroughTheRealWriter()
        throws
    {
        let folders = FolderAccountsTests()
        let (t, context) = try folders.setUp()
        defer { withExtendedLifetime(t) {} }
        _ = try folders.link(context)
        let tool = try Self.loggingTool(in: t.home)
        let vm = ManageViewModel(
            context: context, runner: CLIRunner(context: context, candidates: [tool.exe]),
            clock: { Self.now })
        vm.windowOpened()
        let store = ConfigStore(context: context)
        let folder = try FolderPaths.configDir(context: context, label: "spare")

        /// One sign-in check through the folder kind's own rules.
        func check(loggedIn: Bool = true, email: String = "acct@example.com", in dir: String?)
            throws -> AuthObservation
        {
            let account = try #require(try store.loadRequired().account("spare"))
            let status = AuthStatus(
                loggedIn: loggedIn, email: email, planTier: loggedIn ? "max_20x" : nil,
                configDirectory: dir)
            return AuthObservation(
                FolderKind.evaluate(status, account: account, folder: folder, now: Date()))
        }
        /// A rebuild with what one command saw, then the row's tier and what the window shows.
        func after(
            auth: AuthObservation? = nil, probe: ProbeObservation? = nil,
            settings: SettingsObservation? = nil
        ) throws -> (code: String?, tier: String?, seen: Seen, check: String?) {
            var observations = StatusObservations()
            observations.auth["spare"] = auth
            observations.probe["spare"] = probe
            observations.settings = settings
            let row = try Self.row(
                try StatusBuilder.rebuild(context: context, observations: observations), "spare")
            vm.statusMayHaveChanged()
            return (row.error?.code, row.planTier, try Self.seen(vm, "spare"), row.signInCheck)
        }
        let own = folder.path
        let failed = ProbeObservation(
            error: Issue(.checkFailed, .error, "Check failed: probe timed out."))
        let rejected = ProbeObservation(error: Issue(.loginRejected, .error, "Login rejected."))
        // Dated when each probe runs, so its reading is newer than a rejection recorded before it.
        func worked() -> ProbeObservation { ProbeObservation(error: nil, readAt: .at(Date())) }

        var got = try after(auth: try check(in: own))
        #expect(got.code == nil && got.tier == "max_20x" && got.seen == .signedIn)
        #expect(got.check == "signed_in")
        // Signed in, but in another folder, or in a folder the check does not report: a sign-in
        // `login --browser` would refuse, so no Sign in.
        got = try after(auth: try check(in: "/elsewhere/.claude"))
        #expect(got.code == "check_failed" && got.tier == nil && got.seen == .notConfirmed)
        #expect(got.check == "not_confirmed")
        got = try after(auth: try check(in: own))
        #expect(got.seen == .signedIn)
        got = try after(auth: try check(in: nil))
        #expect(got.code == "check_failed" && got.tier == nil && got.seen == .notConfirmed)
        // Logged out; a probe that then works does not bring the old tier back.
        got = try after(auth: try check(loggedIn: false, in: own))
        #expect(got.code == "login_rejected" && got.tier == nil && got.seen == .signedOut)
        #expect(got.check == "signed_out")
        got = try after(probe: worked())
        #expect(got.code == nil && got.tier == nil && got.seen == .notSignedIn)
        got = try after(auth: try check(in: own))
        #expect(got.seen == .signedIn)
        // A probe that saw it logged out, then a check that sees only the old sign-in, as
        // `status` makes it: the rejection stands, so no "Signed in".
        got = try after(probe: rejected)
        #expect(got.code == "login_rejected" && got.tier == nil && got.seen == .signedOut)
        got = try after(auth: try check(in: own))
        #expect(got.code == "login_rejected" && got.tier == nil && got.seen == .signedOut)
        #expect(got.check == "signed_in")
        // The check `login` makes once it completed a new sign-in ends the rejection.
        var signedInAgain = try check(in: own)
        signedInAgain.newSignIn = true
        got = try after(auth: signedInAgain)
        #expect(got.code == nil && got.tier == "max_20x" && got.seen == .signedIn)

        // Ended: the row's code is `account_ended`, which hides what the checks said.
        var config = try store.loadRequired()
        let index = try #require(config.accounts.firstIndex { $0.label == "spare" })
        config.accounts[index].endsAt = "2026-01-01"
        try store.save(config)
        got = try after()
        #expect(got.code == "account_ended" && got.tier == "max_20x" && got.seen == .signedIn)
        // A doubt since the check that placed it: not "Signed in", and no Sign in either.
        got = try after(probe: rejected)
        #expect(got.code == "account_ended" && got.tier == nil && got.seen == .notConfirmed)
        got = try after(auth: try check(in: own))
        #expect(got.seen == .notConfirmed)
        got = try after(auth: try check(loggedIn: false, in: own))
        #expect(got.code == "account_ended" && got.tier == nil && got.seen == .notSignedIn)
        got = try after(auth: try check(in: own))
        got = try after(probe: failed)
        #expect(got.code == "account_ended" && got.tier == nil && got.seen == .notConfirmed)
        config.accounts[index].endsAt = nil
        try store.save(config)

        // A changed hook record shows first and hides a failed probe under it.
        got = try after(
            probe: worked(),
            settings: SettingsObservation(issue: "changed", carriesKey: false))
        #expect(got.code == "settings_changed" && got.tier == "max_20x" && got.seen == .signedIn)
        got = try after(probe: failed)
        #expect(got.code == "settings_changed" && got.tier == nil && got.seen == .notConfirmed)
        got = try after(
            probe: worked(),
            settings: SettingsObservation(issue: nil, carriesKey: false))
        #expect(got.code == nil && got.seen == .signedIn)

        // Signed in to another account in its own folder: no tier of that account is kept.
        got = try after(auth: try check(email: "other@example.com", in: own))
        #expect(got.code == "wrong_account" && got.seen == .otherAccount)
        #expect(got.check == "other_account" && got.tier == nil)
        #expect(Self.lines(tool.log).isEmpty)
    }
}
