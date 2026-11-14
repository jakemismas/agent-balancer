import Core
import SwiftUI

/// The inside of the Manage accounts window: the account list on the left, the panel for the
/// selected account's kind on the right, and the bar with the last command at the bottom. The
/// title bar belongs to the real window (and to the frame the render tool draws).
struct ManageContent: View {
    let rows: [ManageListRow]
    let selection: String?
    let panel: ManagePanel?
    let notice: String?
    let bar: ManageBar?
    let offReason: String?
    let canAdd: Bool
    var removeEnabled: Bool
    @Binding var endsDate: String
    let actions: ManageActions

    @Environment(\.colorScheme) private var scheme
    @Environment(\.flatMaterials) private var flat

    private var palette: Palette { Palette.of(scheme) }

    var body: some View {
        VStack(spacing: 0) {
            if let offReason {
                HStack(spacing: 8) {
                    WarnTriangle(color: palette.crit).frame(width: 11, height: 10)
                    Text(offReason).font(.ui(11.5)).foregroundStyle(palette.text1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(palette.errBg)
            }
            HStack(spacing: 0) {
                sidebar.frame(width: 196)
                Rectangle().fill(palette.sep).frame(width: 1)
                detail.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 346)
            footer
        }
        .background(palette.winBg)
        .foregroundStyle(palette.text1)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            listBody
            Spacer(minLength: 14)
            HStack(spacing: 0) {
                plusMinus("+", label: "Add account", enabled: canAdd, action: actions.openAdd)
                plusMinus(
                    "\u{2212}", label: "Remove account", enabled: removeEnabled,
                    action: actions.openRemove)
                Spacer(minLength: 0)
            }
            .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 1) }
        }
        .padding(.top, 8)
        .background(palette.winSide)
    }

    @ViewBuilder private var listBody: some View {
        let list = VStack(spacing: 0) {
            ForEach(rows) { row in
                AccountListRow(
                    row: row, selected: row.label == selection,
                    select: { actions.select(row.label) })
            }
        }
        .padding(.horizontal, 6)
        if flat {
            list
        } else {
            ScrollView(.vertical) { list }
        }
    }

    private func plusMinus(
        _ glyph: String, label: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(glyph).font(.ui(16)).foregroundStyle(palette.text1)
                .frame(width: 32, height: 26)
                .overlay(alignment: .trailing) { Rectangle().fill(palette.sep).frame(width: 1) }
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label).help(label)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let panel {
            ManagePanelView(
                panel: panel, endsDate: $endsDate, actions: actions, removeEnabled: removeEnabled)
        } else {
            Text(notice ?? "Pick an account.").font(.ui(12)).foregroundStyle(palette.text2)
                .padding(18)
        }
    }

    // MARK: Footer

    /// The bar read as one sentence: the command and its result or error text.
    private var barSpoken: String {
        guard let bar else { return "No change yet." }
        let cmd = bar.command.isEmpty ? "" : " " + bar.command + "."
        return
            "Last change at \(ManageFooter.time(bar.at)).\(cmd) \(bar.ok ? "Done" : "Failed"): \(bar.text)"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if let bar {
                    Text(bar.ok ? "\u{2713}" : "\u{2715}").font(.ui(11, .bold))
                        .foregroundStyle(bar.ok ? palette.good : palette.crit)
                    Text("Last change, \(ManageFooter.time(bar.at)):").font(.ui(11))
                        .foregroundStyle(palette.text2)
                    if !bar.command.isEmpty {
                        Text(bar.command).font(.ui(11, mono: true)).foregroundStyle(palette.text1)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 5).fill(palette.fieldBg))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5).stroke(
                                    palette.fieldBorder, lineWidth: 0.5))
                    } else {
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("No change yet.").font(.ui(11)).foregroundStyle(palette.text2)
                    Spacer(minLength: 0)
                }
            }
            if let bar, !bar.ok, !bar.text.isEmpty {
                Text(bar.text).font(.ui(11)).foregroundStyle(palette.crit)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(palette.winBar)
        .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 1) }
        .help(bar?.text ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(barSpoken)
    }
}

enum ManageFooter {
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = LocalTime.zone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

struct AccountListRow: View {
    let row: ManageListRow
    let selected: Bool
    let select: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette.of(scheme)
        Button(action: select) {
            HStack(spacing: 8) {
                Circle().fill(row.signedIn ? palette.good : palette.crit).frame(width: 8, height: 8)
                    .overlay(
                        Circle().stroke(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5)
                            .padding(-1.5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.label).font(.ui(13, .semibold))
                    Text(row.subtitle).font(.ui(10.5))
                        .foregroundStyle(selected ? Color.white.opacity(0.88) : palette.text2)
                }
                Spacer(minLength: 0)
                if row.isMain { SmallBadge(text: "main", main: true, selected: selected) }
            }
            .foregroundStyle(selected ? Color.white : palette.text1)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? palette.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The panel for one account: Sign-in, then Token or Folder and Shared settings, then Ends and
/// Remove. A `login` account has only its sign-in state and role.
struct ManagePanelView: View {
    let panel: ManagePanel
    @Binding var endsDate: String
    let actions: ManageActions
    let removeEnabled: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.flatMaterials) private var flat

    private var palette: Palette { Palette.of(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(panel.label).font(.ui(16, .semibold))
                SmallBadge(text: panel.roleBadge, main: panel.isMain)
            }
            HStack(spacing: 6) {
                if let email = panel.emailLine {
                    Text(email).font(.ui(12)).foregroundStyle(palette.text2)
                }
                if let tip = panel.emailTip { TipMark(text: tip, palette: palette) }
            }
            .padding(.top, 1).padding(.bottom, 10)

            group("Sign-in") { signIn }
            if let problem = panel.problem {
                VStack(alignment: .leading, spacing: 4) {
                    Text(problem.title).font(.ui(11.5, .semibold)).foregroundStyle(palette.crit)
                    Text(problem.text).font(.ui(11.5)).foregroundStyle(palette.text1)
                        .fixedSize(horizontal: false, vertical: true)
                    StepsView(steps: problem.steps, palette: palette, copy: actions.copy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.errBg))
                .padding(.bottom, 8)
            }
            if panel.kind == .token { group("Token") { token } }
            if panel.kind == .folder {
                group("Folder") { folder }
                group("Shared settings") { shared }
            }
            if panel.kind != .login {
                group("Ends") { ends }
                removeGroup
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.ui(11, .semibold)).foregroundStyle(palette.text2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 9).padding(.bottom, 10)
        .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 1) }
    }

    /// The state, then the button, or the command to run in Terminal on its own line so it is
    /// never cut short.
    private var signIn: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(panel.signedIn ? palette.good : palette.crit).frame(
                    width: 8, height: 8)
                Text(panel.signInText).font(.ui(13)).lineLimit(1)
                if let tip = panel.signInTip { TipMark(text: tip, palette: palette) }
                Spacer(minLength: 0)
                if let control = panel.signIn, control.mode == .run {
                    ChromeButton(
                        title: control.title, style: .primary, enabled: control.enabled,
                        action: actions.signIn)
                }
            }
            if let control = panel.signIn, control.mode == .showCommand {
                HStack(spacing: 8) {
                    Text("In Terminal:").font(.ui(11)).foregroundStyle(palette.text2)
                    CommandField(command: control.command, fill: true, copy: actions.copy)
                }
            }
            if let note = panel.signInNote {
                Text(note).font(.ui(11)).foregroundStyle(palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var token: some View {
        HStack(spacing: 6) {
            Text(panel.tokenExpires ?? "").font(.ui(13))
            if let tip = panel.tokenTip { TipMark(text: tip, palette: palette) }
        }
    }

    private var folder: some View {
        HStack(spacing: 8) {
            Text(panel.folderPath ?? "").font(.ui(11, mono: true)).foregroundStyle(palette.text1)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(palette.fieldBg))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).stroke(palette.fieldBorder, lineWidth: 0.5))
            if let path = panel.folderPath {
                CopyChip(text: path, what: "folder path", copy: actions.copy)
            }
        }
    }

    private var shared: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(panel.sharedOK ? palette.good : palette.crit).frame(
                    width: 8, height: 8)
                Text(panel.sharedText ?? "").font(.ui(13))
                if let tip = panel.sharedTip { TipMark(text: tip, palette: palette) }
            }
            if let command = panel.linkCommand {
                CommandField(command: command, copy: actions.copy)
            }
        }
    }

    private var ends: some View {
        VStack(alignment: .leading, spacing: 0) {
            RadioRow(
                title: "Never", on: panel.ends == .never, enabled: panel.canChangeEnds,
                action: { actions.changeEnds(.never) })
            RadioRow(
                title: "Soon, date unknown", on: panel.ends == .soon, enabled: panel.canChangeEnds,
                action: { actions.changeEnds(.soon) }
            ) {
                TipMark(text: panel.endingSoonTip, palette: palette)
            }
            RadioRow(
                title: "On", on: isDate, enabled: panel.canChangeEnds,
                action: { actions.changeEnds(.on(isoDate)) }
            ) {
                TipMark(text: panel.endsOnTip, palette: palette)
                EndDateField(iso: shownDate, enabled: panel.canChangeEnds) {
                    actions.changeEnds(.on($0))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ends")
    }

    /// The account's own date when it has one, else the date the "On" choice will use.
    private var shownDate: Binding<String> {
        Binding(get: { isoDate }, set: { endsDate = $0 })
    }

    private var isDate: Bool {
        if case .on = panel.ends { return true }
        return false
    }

    private var isoDate: String {
        if case .on(let date) = panel.ends { return date }
        return endsDate
    }

    @ViewBuilder private var removeGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 0)
                ChromeButton(
                    title: "Remove account\u{2026}", style: .danger, enabled: removeEnabled,
                    action: actions.openRemove)
            }
            if let command = panel.remove?.terminalCommand {
                HStack(spacing: 8) {
                    Text("In Terminal:").font(.ui(11)).foregroundStyle(palette.text2)
                    CommandField(command: command, copy: actions.copy)
                }
            }
        }
        .padding(.top, 9).padding(.bottom, 2)
        .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 1) }
    }
}

/// The date of the "On" end choice. The real window uses the system date picker, which takes
/// today or later; the render tool draws the same text in a field because it cannot draw the
/// picker.
struct EndDateField: View {
    @Binding var iso: String
    let enabled: Bool
    let changed: (String) -> Void
    @Environment(\.flatMaterials) private var flat
    @Environment(\.colorScheme) private var scheme

    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        if flat {
            let palette = Palette.of(scheme)
            FieldBox { Text(longText).foregroundStyle(palette.text3) }
        } else {
            DatePicker(
                "End date", selection: dateBinding, in: Calendar.current.startOfDay(for: Date())...,
                displayedComponents: .date
            )
            .labelsHidden().datePickerStyle(.compact).disabled(!enabled)
            .accessibilityLabel("End date")
        }
    }

    private var longText: String {
        guard let date = Self.format.date(from: iso) else { return Display.safe(iso, limit: 32) }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "MMM d, yyyy"
        return out.string(from: date)
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { Self.format.date(from: iso) ?? Date() },
            set: {
                let text = Self.format.string(from: $0)
                iso = text
                changed(text)
            })
    }
}
