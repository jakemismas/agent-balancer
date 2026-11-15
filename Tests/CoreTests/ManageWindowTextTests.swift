import Foundation
import Testing

@testable import Core

/// The window's texts: one end wording for every kind, a token's time left that never reads
/// "Expired" beside a green dot, and the command that fixes an email `login --browser` refuses.
extension ManageViewModelTests {
    /// A status document with these account rows.
    static func textJson(_ rows: [String]) -> String {
        """
        { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": null,
          "accounts": [ \(rows.joined(separator: ", ")) ] }
        """
    }

    @Test @MainActor func everyKindsEndedRowUsesOneEndWording() throws {
        let ended =
            #""state": "ended", "error": { "code": "account_ended", "text": "Account ended." }"#
        let placed = #""linked": true, "planTier": "max_20x", "signInCheck": "signed_in""#
        let json = Self.textJson([
            #"{ "label": "tok", "role": "pool", "kind": "token", "endsAt": "2026-11-01", \#(ended) }"#,
            #"{ "label": "log", "role": "pool", "kind": "login", "endsAt": "2026-11-01", \#(ended) }"#,
            #"{ "label": "log-plan", "role": "pool", "kind": "login", "endingSoon": true, \#(ended) }"#,
            #"{ "label": "fol", "role": "pool", "kind": "folder", "endsAt": "2026-11-01", \#(placed), \#(ended) }"#,
            #"{ "label": "fol-plan", "role": "pool", "kind": "folder", "endingSoon": true, \#(placed), \#(ended) }"#,
            // Ended by its plan with a date still ahead: the date is not the end.
            #"{ "label": "fol-ahead", "role": "pool", "kind": "folder", "endsAt": "2026-12-31", \#(placed), \#(ended) }"#,
        ])
        let vm = Self.model(try Fake(statusJson: json))
        let lines = Dictionary(uniqueKeysWithValues: vm.rows.map { ($0.label, $0.subtitle) })
        #expect(lines["tok"] == "Ended Nov 1")
        #expect(lines["log"] == "Ended Nov 1")
        #expect(lines["log-plan"] == "Ended")
        #expect(lines["fol"] == "Signed in \u{00B7} ended Nov 1")
        #expect(lines["fol-plan"] == "Signed in \u{00B7} ended")
        #expect(lines["fol-ahead"] == "Signed in \u{00B7} ended")
        for (label, line) in lines { #expect(!line.contains("ends "), "\(label)") }
    }

    @Test @MainActor func aTokenReadsItsTimeLeftAndNeverExpiredBesideAGreenDot() throws {
        let formatter = ISO8601DateFormatter()
        let day = 86_400.0
        // Time left from the window's clock, and what the list line reads.
        let table: [(left: TimeInterval, line: String)] = [
            (0.5 * day, "Less than a day left"), (day, "1 day left"), (1.5 * day, "1 day left"),
            (2 * day, "2 days left"), (2.5 * day, "2 days left"), (400 * day, "400 days left"),
            // The 365-day estimate has passed while the probe still works.
            (-day, "Signed in"), (-400 * day, "Signed in"),
        ]
        let rows = table.enumerated().map { index, entry in
            let at = formatter.string(from: Self.now.addingTimeInterval(entry.left))
            return #"{ "label": "t\#(index)", "role": "pool", "kind": "token", "state": "ok", "#
                + #""loginExpiresAt": "\#(at)", "loginExpiresSource": "estimate" }"#
        }
        let vm = Self.model(try Fake(statusJson: Self.textJson(rows)))
        for (index, entry) in table.enumerated() {
            let row = try #require(vm.rows.first { $0.label == "t\(index)" })
            #expect(row.subtitle == entry.line, "\(entry.left / day) days: \(row.subtitle)")
            #expect(row.signedIn && !row.subtitle.contains("Expired"), "\(entry.left / day) days")
        }
    }

    @Test @MainActor func anEmailLoginRefusesShowsTheCommandThatChangesItAndAddStepThreeSaysWhy()
        async throws
    {
        let json = Self.textJson([
            #"{ "label": "fol-dash", "email": "-fol-dash@example.com", "role": "pool", "kind": "folder", "#
                + #""fullLogin": true, "linked": true, "signInCheck": "signed_out", "state": "error", "#
                + #""error": { "code": "login_rejected", "text": "Login rejected." } }"#
        ])
        let fake = try Fake(statusJson: json)
        let vm = Self.model(fake)
        vm.selection = "fol-dash"
        let panel = try #require(vm.panel)
        let note = MenuBuilder.plain(Messages.emailNotPlain("fol-dash"))
        #expect(panel.signIn == nil && panel.signInNote == note)
        #expect(panel.signInNoteCommand == "agent-balancer config set fol-dash email <address>")
        var draft = AddDraft()
        draft.label = "fol-dash"
        draft.kind = Kind.folder
        draft.stage = .added
        let step = try #require(vm.addSteps(draft).first { $0.id == 3 })
        #expect(!step.actionEnabled && step.note == note)
        // The panel and the step show the command and the reason; the window runs nothing.
        await vm.signIn("fol-dash")
        #expect(fake.calls().isEmpty)
    }
}
