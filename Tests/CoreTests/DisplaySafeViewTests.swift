import Foundation
import Testing

@testable import Core

/// Every string from the status file that reaches a view, in the menu and in the Manage accounts
/// window, passes the display-safe pass: control and bidi characters show as escapes and an
/// over-long value is cut.
@Suite(.serialized) struct DisplaySafeViewTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-09T21:13:00Z")!

    static let values: [(name: String, value: String, mark: String)] = [
        ("control", "a\u{07}b\u{1B}[31mc\u{0}d\ne", "\\u{1b}"),
        ("bidi", "a\u{202E}gnp.exe\u{2066}b\u{200F}c", "\\u{202e}"),
        ("long", String(repeating: "w", count: 5000), "www..."),
    ]

    /// Every string inside a model, found by reflection so no field is left out.
    static func strings(in value: Any) -> [String] {
        if let text = value as? String { return [text] }
        return Mirror(reflecting: value).children.flatMap { strings(in: $0.value) }
    }

    static func isSafe(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse,
                .unassigned:
                return true
            default:
                return false
            }
        }
    }

    static func account(_ changes: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [
            "label": "acct", "email": "acct@example.com", "role": "pool", "kind": "token",
            "state": "ok", "weekly": ["usedPercent": 10.0], "warnings": [[String: Any]](),
        ]
        out.merge(changes) { _, new in new }
        return out
    }

    static func document(_ account: [String: Any], extra: [String: Any] = [:]) throws -> Data {
        var out: [String: Any] = [
            "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "accounts": [account],
        ]
        out.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: out)
    }

    /// Each field the sweep found, the document that puts a value in it, and whether the menu
    /// and the window show that field.
    static var fields: [(name: String, menu: Bool, window: Bool, make: (String) throws -> Data)] {
        [
            ("label", true, false, { try document(account(["label": $0])) }),
            ("email", true, true, { try document(account(["email": $0])) }),
            ("endsAt", true, true, { try document(account(["endsAt": $0])) }),
            (
                "error code", true, false,
                {
                    try document(
                        account(["state": "error", "error": ["code": $0, "text": "Bad."]]))
                }
            ),
            (
                "error text", true, true,
                {
                    try document(
                        account([
                            "kind": "folder", "configDir": "~/x", "linked": true, "state": "error",
                            "error": ["code": "wrong_account", "text": $0],
                        ]))
                }
            ),
            (
                "ended text", true, false,
                {
                    try document(
                        account(["state": "ended", "error": ["code": "account_ended", "text": $0]]))
                }
            ),
            (
                "warning text", true, false,
                { try document(account(["warnings": [["code": "plan_changed", "text": $0]]])) }
            ),
            // The window shows the folder path it makes from the label, never this value.
            (
                "configDir", false, false,
                { try document(account(["kind": "folder", "configDir": $0, "linked": true])) }
            ),
            // Only a plain tier is read, so none of these values is shown.
            (
                "planTier", false, false,
                { try document(account(["kind": "folder", "planTier": $0, "linked": true])) }
            ),
            (
                "banner text", true, false,
                {
                    try document(
                        account([:]), extra: ["banner": ["code": "settings_changed", "text": $0]])
                }
            ),
            (
                "next label", true, false,
                {
                    try document(
                        account([:]),
                        extra: [
                            "next": [
                                "all": ["label": $0, "reason": "r"],
                                "fable": ["label": $0, "reason": "r"],
                            ]
                        ])
                }
            ),
            (
                "next reason", true, false,
                {
                    try document(
                        account([:]),
                        extra: [
                            "next": [
                                "all": ["label": "acct", "reason": $0],
                                "fable": ["label": "acct", "reason": $0],
                            ]
                        ])
                }
            ),
        ]
    }

    /// What the menu shows for one status document.
    static func menuStrings(_ data: Data) -> [String] {
        let screen = MenuBuilder.screen(
            MenuInputs(
                configExists: true, cliFound: true, cliTried: [],
                status: StatusSnapshot.parse(data), now: now, backgroundMinutes: 60))
        return strings(in: screen)
    }

    /// What the Manage accounts window shows for one status document: the list and every panel.
    @MainActor static func windowStrings(_ data: Data) throws -> [String] {
        let home = try TestHome()
        let context = home.context
        try NoFollowWriter(root: context.dataRoot).put(
            data, folders: ["state"], name: "status.json")
        let vm = ManageViewModel(
            context: context, runner: CLIRunner(context: context, candidates: []),
            clock: { now })
        var out = strings(in: vm.rows) + [vm.notice ?? ""]
        for row in vm.rows {
            vm.selection = row.label
            out += strings(in: vm.panel as Any)
        }
        return out
    }

    @Test @MainActor func everyStatusStringTheViewsShowIsDisplaySafe() throws {
        for field in Self.fields {
            for value in Self.values {
                let data = try field.make(value.value)
                let place = "\(field.name), \(value.name)"
                var shown = Self.menuStrings(data)
                if field.menu {
                    #expect(shown.contains { $0.contains(value.mark) }, "menu: \(place)")
                }
                let window = try Self.windowStrings(data)
                if field.window {
                    #expect(window.contains { $0.contains(value.mark) }, "window: \(place)")
                }
                shown += window
                for text in shown {
                    #expect(Self.isSafe(text), "\(place)")
                    #expect(text.count <= 600, "\(place)")
                }
            }
        }
    }

    @Test @MainActor func aLabelThatIsNotAPlainLabelIsNotListedInTheWindow() throws {
        for value in Self.values {
            let data = try Self.document(Self.account(["label": value.value]))
            let home = try TestHome()
            try NoFollowWriter(root: home.context.dataRoot).put(
                data, folders: ["state"], name: "status.json")
            let vm = ManageViewModel(
                context: home.context, runner: CLIRunner(context: home.context, candidates: []),
                clock: { Self.now })
            #expect(vm.rows.isEmpty, "\(value.name)")
        }
    }

    @Test func aDayThatIsNotADateIsShownThroughTheSafePass() {
        #expect(MenuFormat.day("2026-11-16") == "Nov 16")
        #expect(MenuFormat.day("2026-13-45") == "2026-13-45")
        #expect(MenuFormat.day("2026-11-16\u{202E}") == "2026-11-16\\u{202e}")
        #expect(MenuFormat.day(String(repeating: "9", count: 100)).hasSuffix("..."))
        #expect(ManageFormat.longDay("2026-11-16") == "Nov 16, 2026")
        #expect(ManageFormat.longDay("x\u{07}") == "x\\u{7}")
    }
}
