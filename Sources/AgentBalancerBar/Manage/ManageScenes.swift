import Core
import Foundation
import SwiftUI

/// Fixed data for the render tool: the frames of design/render.html for the Manage accounts
/// window. Labels and example.com addresses only.
enum ManageScenes {
    static let now = RenderScenes.now
    static let barTime = ISO8601DateFormatter().date(from: "2026-11-09T21:12:00Z") ?? Date()

    static func accounts(folder: Bool) -> String {
        let kind = folder ? "folder" : "token"
        func account(
            _ label: String, role: String = "pool", email: String, kind: String, extra: String = ""
        ) -> String {
            """
            { "label": "\(label)", "email": "\(email)", "role": "\(role)", "kind": "\(kind)",
              "state": "ok", \(extra) "weekly": null }
            """
        }
        let spareB: String
        if folder {
            spareB = """
                { "label": "spare-b", "email": "spare-b@example.com", "role": "pool", "kind": "folder",
                  "fullLogin": true, "configDir": "~/.agent-balancer/accounts/spare-b/.claude",
                  "linked": true, "endingSoon": true, "state": "error", "planTier": "Ultra",
                  "stateSince": "2026-11-09T20:40:00Z",
                  "error": { "code": "login_rejected", "text": "Logged out." }, "weekly": null }
                """
        } else {
            spareB = """
                { "label": "spare-b", "email": "spare-b@example.com", "role": "pool", "kind": "token",
                  "endingSoon": true, "state": "error", "stateSince": "2026-11-09T20:40:00Z",
                  "error": { "code": "token_missing", "text": "No token." },
                  "loginExpiresAt": "2027-03-02T20:00:00Z", "loginExpiresSource": "estimate",
                  "weekly": null }
                """
        }
        // A folder reads as signed in only with the plan tier a signed-in check writes.
        let signedInFolder = "\"linked\": true, \"planTier\": \"max_20x\","
        let personal = account(
            "personal", email: "personal@example.com", kind: kind,
            extra: folder
                ? signedInFolder
                : "\"loginExpiresAt\": \"2027-10-27T10:00:00Z\", \"loginExpiresSource\": \"estimate\","
        )
        let lab = account(
            "lab", email: "lab@example.com", kind: kind,
            extra: folder
                ? signedInFolder
                : "\"loginExpiresAt\": \"2027-11-10T10:00:00Z\", \"loginExpiresSource\": \"estimate\","
        )
        let spareA = account(
            "spare-a", email: "spare-a@example.com", kind: kind,
            extra: "\"endsAt\": \"2026-11-16\", " + (folder ? signedInFolder : ""))
        return """
            { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": null,
              "accounts": [
                { "label": "main", "email": "main@example.com", "role": "main", "kind": "login",
                  "fullLogin": true, "state": "ok", "weekly": null },
                \(personal), \(lab), \(spareA), \(spareB) ] }
            """
    }

    static func snapshot(_ json: String) -> [AccountSnapshot] {
        if case .loaded(let s) = StatusSnapshot.parse(Data(json.utf8)) { return s.accounts }
        return []
    }

    @MainActor static func window(folder: Bool, settings: ManageSettings = ManageSettings())
        -> AnyView
    {
        let accounts = snapshot(accounts(folder: folder))
        let rows = accounts.map { ManageBuilder.listRow($0, now: now) }
        let selected = accounts.last
        let panel = selected.map {
            ManageBuilder.panel(
                $0, settings: settings, now: now, checked: ManageScenes.checked,
                folderPath: ManageBuilder.folderPath($0.label, context: home))
        }
        let bar = ManageBar(
            command: "agent-balancer config set spare-b ending-soon true", ok: true,
            text: "Updated ending-soon.", at: barTime)
        return AnyView(
            WindowFrame {
                ManageContent(
                    rows: rows, selection: selected?.label, panel: panel, notice: nil, bar: bar,
                    offReason: nil, canAdd: true, removeEnabled: panel?.remove?.enabled ?? false,
                    endsDate: .constant("2026-11-16"), actions: ManageActions())
            })
    }

    static let checked = ISO8601DateFormatter().date(from: "2026-11-09T21:11:00Z")

    /// A made-up home, so the folder path reads as the window shows it: under `~`.
    static let home = ToolContext(home: URL(fileURLWithPath: "/Users/example"), ambient: [:])

    /// The new folder account's row as the tool writes it right after `add --kind folder`.
    static let addedFolder = """
        { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": null,
          "accounts": [
            { "label": "spare", "email": "spare@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "configDir": "~/.agent-balancer/accounts/spare/.claude",
              "linked": false, "state": "error",
              "error": { "code": "not_linked", "text": "Settings not shared." }, "weekly": null } ] }
        """

    @MainActor static func addSheet(folder: Bool, settings: ManageSettings = ManageSettings())
        -> AnyView
    {
        var draft = AddDraft(endDate: "2026-11-16")
        draft.label = "spare"
        draft.email = "spare@example.com"
        draft.kind = folder ? Kind.folder : Kind.token
        if folder { draft.stage = .added }
        let steps = ManageBuilder.addSteps(
            draft, account: snapshot(addedFolder).first, settings: settings, canAct: true,
            now: now)
        return AnyView(
            AddSheetContent(
                draft: .constant(draft), problem: nil, steps: steps, busy: false,
                tokenMode: settings.tokenSignIn, actions: AddSheetActions()
            )
            .sheetFrame())
    }

    @MainActor static func removeSheet() -> AnyView {
        var draft = RemoveDraft(
            label: "spare-a",
            text: "It stops getting workers and its token file is deleted. Its chats stay.")
        draft.typed = "spare-a"
        return AnyView(
            RemoveSheetContent(
                draft: .constant(draft), canConfirm: true, actions: RemoveSheetActions()
            )
            .sheetFrame())
    }

    /// Rows as the tool writes them under a hook change: a folder signed in to another account,
    /// one whose sign-in the check could not place, one signed in, an ended token account and
    /// the login account. The selected folder's last check found another account, which the
    /// hook change hides from its code.
    static let statesJson = """
        { "schemaVersion": 1, "generatedAt": "2026-11-09T21:10:00Z", "banner": null,
          "accounts": [
            { "label": "main", "email": "main@example.com", "role": "main", "kind": "login",
              "fullLogin": true, "state": "error", "weekly": null,
              "error": { "code": "settings_changed", "text": "Settings changed. Run `agent-balancer link --accept-source-change --all` in Terminal." } },
            { "label": "personal", "email": "personal@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "linked": true, "planTier": "max_20x", "signInCheck": "signed_in",
              "state": "error", "weekly": null,
              "error": { "code": "settings_changed", "text": "Settings changed. Run `agent-balancer link --accept-source-change --all` in Terminal." } },
            { "label": "lab", "email": "lab@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "linked": true, "signInCheck": "other_account",
              "state": "error", "weekly": null,
              "error": { "code": "settings_changed", "text": "Settings changed. Run `agent-balancer link --accept-source-change --all` in Terminal." } },
            { "label": "spare-a", "email": "spare-a@example.com", "role": "pool", "kind": "token",
              "state": "ended", "endsAt": "2026-11-01", "weekly": null,
              "error": { "code": "account_ended", "text": "Account ended." } },
            { "label": "spare-b", "email": "spare-b@example.com", "role": "pool", "kind": "folder",
              "fullLogin": true, "linked": true, "signInCheck": "not_confirmed",
              "state": "error", "weekly": null,
              "error": { "code": "check_failed", "text": "Check failed: the sign-in is not in this account's own folder." } } ] }
        """

    /// The window over `statesJson`, after the folder's own Sign in found another account.
    @MainActor static func statesWindow() -> AnyView {
        let accounts = snapshot(statesJson)
        let rows = accounts.map { ManageBuilder.listRow($0, now: now) }
        let panel = accounts.first { $0.label == "lab" }.map {
            ManageBuilder.panel(
                $0, settings: ManageSettings(), now: now, checked: ManageScenes.checked,
                folderPath: ManageBuilder.folderPath($0.label, context: home))
        }
        let bar = ManageBar(
            command: "agent-balancer login lab --browser", ok: false,
            text: "Error wrong_account: Folder is logged in as another account.", at: barTime)
        return AnyView(
            WindowFrame {
                ManageContent(
                    rows: rows, selection: "lab", panel: panel, notice: nil, bar: bar,
                    offReason: nil, canAdd: true, removeEnabled: panel?.remove?.enabled ?? false,
                    endsDate: .constant("2026-11-16"), actions: ManageActions())
            })
    }

    @MainActor static func all() -> [(String, AnyView)] {
        [
            ("manage-token", window(folder: false)),
            ("manage-folder", window(folder: true)),
            (
                "manage-token-run",
                window(folder: false, settings: ManageSettings(tokenSignIn: .run))
            ),
            ("manage-add-token", addSheet(folder: false)),
            ("manage-add-folder", addSheet(folder: true)),
            ("manage-remove", removeSheet()),
            ("manage-states", statesWindow()),
        ]
    }
}

/// The window frame of design/render.html: traffic lights, the tile icon and the title. The real
/// window has its own title bar.
struct WindowFrame<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette.of(scheme)
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { hex in
                        Circle().fill(Palette.rgb(UInt32(hex))).frame(width: 12, height: 12)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 13)
                HStack(spacing: 7) {
                    TileIcon().frame(width: 18, height: 18)
                    Text("Manage accounts").font(.ui(13, .semibold))
                }
            }
            .frame(height: 38).frame(maxWidth: .infinity)
            .background(palette.winBar)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.sep).frame(height: 1) }
            content
        }
        .foregroundStyle(palette.text1)
        .frame(width: 648)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.panelBorder, lineWidth: 0.5))
    }
}

extension View {
    /// A sheet drawn alone: rounded, with the window border.
    func sheetFrame() -> some View { modifier(SheetFrame()) }
}

private struct SheetFrame: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = Palette.of(scheme)
        content
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.panelBorder, lineWidth: 0.5))
    }
}
