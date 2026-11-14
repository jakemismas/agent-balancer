import Foundation
import Testing

@testable import Core

/// Rows from an earlier writer, and folders whose expected email `login --browser` refuses.
extension ManageViewModelTests {
    /// A folder row with every key the earlier writer gives one and no `signInCheck`; that
    /// writer kept the plan tier from any check that saw a sign-in, another account's included.
    static func earlierFolderRow(
        _ label: String, state: String, code: String, text: String, endsAt: String? = nil,
        withKey: Bool = false
    ) -> String {
        let ends = endsAt.map { "\"\($0)\"" } ?? "null"
        let key = withKey ? "\"signInCheck\": null, " : ""
        return """
            { "label": "\(label)", "email": "\(label)@example.com", "role": "pool",
              "kind": "folder", "fullLogin": true,
              "configDir": "~/.agent-balancer/accounts/\(label)/.claude", "accountKey": "\(label)",
              "endingSoon": false, "linked": true, "state": "\(state)",
              "stateSince": "2026-11-09T20:00:00Z", "limited": null,
              "error": { "code": "\(code)", "text": "\(text)" }, "warnings": [],
              "planTier": "max_20x", \(key)
              "weekly": { "usedPercent": null, "resetsAt": null, "source": "none", "readAt": null },
              "fable": { "usedPercent": null, "guaranteedLeftPercentOfCap": null,
                         "possibleLeftPercentOfCap": null, "resetsAt": null, "source": "none" },
              "fiveHour": null, "readingsAge": null, "inUse": { "count": 0, "sessions": [] },
              "endsAt": \(ends), "loginExpiresAt": null, "loginExpiresSource": null,
              "reserve": null }
            """
    }

    @Test @MainActor func aRowFromTheEarlierWriterShowsNoSignInACodeCouldHide() async throws {
        let hook =
            "Settings changed. Run `agent-balancer link --accept-source-change --all` in Terminal."
        let rows = [
            Self.earlierFolderRow("hook", state: "error", code: "settings_changed", text: hook),
            Self.earlierFolderRow(
                "over", state: "ended", code: "account_ended", text: "Account ended.",
                endsAt: "2026-01-01"),
            // The same rows as this version writes them, with the key: the tier then stands.
            Self.earlierFolderRow(
                "hook-now", state: "error", code: "settings_changed", text: hook, withKey: true),
            Self.earlierFolderRow(
                "over-now", state: "ended", code: "account_ended", text: "Account ended.",
                endsAt: "2026-01-01", withKey: true),
        ]
        let json = """
            { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": null,
              "accounts": [ \(rows.joined(separator: ", ")) ] }
            """
        let fake = try Fake(statusJson: json)
        let vm = Self.model(fake)
        vm.windowOpened()
        let expected: [(String, String, Bool, String, String, String)] = [
            (
                "hook", "Sign-in not confirmed", false, "Sign-in not confirmed", "",
                "Settings changed"
            ),
            (
                "over", "Sign-in not confirmed", false,
                "Sign-in not confirmed \u{00B7} ended Jan 1",
                ", ended", "Account ended"
            ),
            ("hook-now", "Signed in", true, "Signed in", "", ""),
            (
                "over-now", "Signed in", true, "Signed in \u{00B7} ended Jan 1", ", ended",
                "Account ended"
            ),
        ]
        for (label, line, green, list, spokenEnd, problem) in expected {
            vm.selection = label
            let panel = try #require(vm.panel, "\(label)")
            #expect(panel.signInText == line && panel.signedIn == green, "\(label)")
            #expect(panel.signIn == nil, "\(label)")
            #expect((panel.problem?.title ?? "") == problem, "\(label)")
            let row = try #require(vm.rows.first { $0.label == label })
            #expect(row.subtitle == list && row.signedIn == green, "\(label): \(row.subtitle)")
            let words = green ? "signed in" : "sign-in not confirmed"
            #expect(row.accessibilityLabel == "\(label), folder account, \(words)\(spokenEnd)")
            var draft = AddDraft()
            draft.label = label
            draft.kind = Kind.folder
            draft.stage = .added
            let step = try #require(vm.addSteps(draft).first { $0.id == 3 })
            #expect(!step.actionEnabled && (step.state == .done) == green, "\(label)")
            await vm.signIn(label)
        }
        #expect(fake.calls().isEmpty)
    }

    @Test @MainActor func aFolderWhoseEmailLoginRefusesOffersNoSignInAndSaysWhy() async throws {
        func row(_ label: String, email: String, code: String? = nil) -> String {
            let error = code.map { ", \"error\": { \"code\": \"\($0)\", \"text\": \"Text.\" }" }
            return """
                { "label": "\(label)", "email": "\(email)", "role": "pool", "kind": "folder",
                  "fullLogin": true, "linked": true, "signInCheck": null,
                  "state": "\(code == nil ? "ok" : "error")"\(error ?? "") }
                """
        }
        // The same two emails `login --browser` refuses and passes.
        #expect(!ConfigValidator.isPlainEmail("-odd@example.com"))
        #expect(!ConfigValidator.isPlainEmail("a b@example.com"))
        #expect(ConfigValidator.isPlainEmail("plain@example.com"))
        let json = """
            { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": null,
              "accounts": [ \(row("plain", email: "plain@example.com")),
                \(row("odd", email: "-odd@example.com")),
                \(row("spaced", email: "a b@example.com", code: "login_rejected")) ] }
            """
        let fake = try Fake(statusJson: json)
        let vm = Self.model(fake)
        vm.windowOpened()
        for (label, line) in [("odd", "Not signed in"), ("spaced", "Signed out")] {
            vm.selection = label
            let panel = try #require(vm.panel, "\(label)")
            #expect(panel.signInText == line, "\(label)")
            #expect(panel.signIn == nil && panel.signInTip == nil, "\(label)")
            #expect(panel.signInNote == MenuBuilder.plain(Messages.emailNotPlain(label)))
            var draft = AddDraft()
            draft.label = label
            draft.kind = Kind.folder
            draft.stage = .added
            let step = try #require(vm.addSteps(draft).first { $0.id == 3 })
            #expect(!step.actionEnabled, "\(label)")
            await vm.signIn(label)
        }
        #expect(fake.calls().isEmpty)
        // A plain email still offers Sign in, and it runs.
        vm.selection = "plain"
        let panel = try #require(vm.panel)
        #expect(panel.signIn?.enabled == true && panel.signInNote == nil)
        await vm.signIn("plain")
        #expect(fake.calls() == ["login plain --browser"])
    }
}
