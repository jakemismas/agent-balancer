import Core
import SwiftUI

/// The Add sheet: the form, and after the account is added the steps still to do.
struct AddSheetContent: View {
    @Binding var draft: AddDraft
    let problem: String?
    let steps: [AddStep]
    let busy: Bool
    let tokenMode: SignInMode
    let actions: AddSheetActions

    @Environment(\.colorScheme) private var scheme
    @Environment(\.flatMaterials) private var flat

    private var palette: Palette { Palette.of(scheme) }
    private var added: Bool { draft.stage == .added }
    private var isToken: Bool { draft.kind == Kind.token }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TileIcon().frame(width: 22, height: 22)
                Text("Add an account").font(.ui(13, .semibold))
                Spacer(minLength: 0)
            }
            .padding(.bottom, 9)
            form
            if !steps.isEmpty { stepList }
            if let error = draft.error {
                Text(error).font(.ui(11.5)).foregroundStyle(palette.crit)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            } else if let problem, !draft.label.isEmpty, !added {
                Text(problem).font(.ui(11)).foregroundStyle(palette.text2).padding(.top, 6)
            }
            buttons
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        .frame(width: 418)
        .background(palette.winBg)
        .foregroundStyle(palette.text1)
    }

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                formLabel("Label")
                field("Label", text: $draft.label)
            }
            GridRow {
                formLabel("Email")
                field("Email", text: $draft.email)
            }
            GridRow {
                formLabel("Kind")
                HStack(spacing: 14) {
                    RadioRow(
                        title: "Token", on: isToken, enabled: !added && !busy,
                        action: { draft.kind = Kind.token })
                    RadioRow(
                        title: "Folder", on: !isToken, enabled: !added && !busy,
                        action: { draft.kind = Kind.folder }
                    ) {
                        TipMark(text: ManageTips.addFolder, palette: palette)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Kind")
            }
            GridRow {
                formLabel("Ends")
                HStack(spacing: 14) {
                    RadioRow(
                        title: "Never", on: draft.end == .never, enabled: !added && !busy,
                        action: { draft.end = .never })
                    RadioRow(
                        title: "Soon", on: draft.end == .soon, enabled: !added && !busy,
                        action: { draft.end = .soon })
                    RadioRow(
                        title: "On a date", on: isDate, enabled: !added && !busy,
                        action: { draft.end = .on(draft.endDate) })
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Ends")
            }
            if isDate {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    EndDateField(iso: $draft.endDate, enabled: !added && !busy) { _ in }
                }
            }
        }
    }

    private var isDate: Bool {
        if case .on = draft.end { return true }
        return false
    }

    private func formLabel(_ text: String) -> some View {
        Text(text).font(.ui(12)).foregroundStyle(palette.text2)
            .frame(width: 44, alignment: .trailing)
    }

    @ViewBuilder private func field(_ name: String, text: Binding<String>) -> some View {
        if flat {
            FieldBox {
                Text(text.wrappedValue.isEmpty ? " " : text.wrappedValue)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            FieldBox {
                TextField(name, text: text).textFieldStyle(.plain).disabled(added || busy)
                    .autocorrectionDisabled()
                    .accessibilityLabel(name)
            }
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 7) {
                    StepMarker(number: step.id, done: step.state == .done)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(step.title).font(.ui(12))
                        if let command = step.command {
                            Text(command).font(.ui(11, mono: true)).foregroundStyle(palette.text2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                    if let title = step.actionTitle {
                        ChromeButton(
                            title: title, small: true, enabled: step.actionEnabled,
                            action: { actions.runStep(step) })
                    } else if let command = step.command, step.state == .todo {
                        CopyChip(text: command, what: "command", copy: actions.copy)
                    }
                }
            }
        }
        .padding(.top, 9).padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(palette.sep).frame(height: 1) }
        .padding(.top, 10)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            // Closing while a command runs would let its result open the sheet again.
            ChromeButton(title: added ? "Close" : "Cancel", enabled: !busy, action: actions.close)
            ChromeButton(
                title: isToken ? "Sign in and add\u{2026}" : "Create folder", style: .primary,
                enabled: !added && !busy && problem == nil, action: actions.submit)
            if isToken {
                TipMark(
                    text: tokenMode == .run ? ManageTips.addTokenRun : ManageTips.addTokenCommand,
                    palette: palette)
            }
        }
        .padding(.top, 12)
    }
}

struct AddSheetActions {
    var copy: (String) -> Void = { _ in }
    var close: () -> Void = {}
    var submit: () -> Void = {}
    var runStep: (AddStep) -> Void = { _ in }
}

struct StepMarker: View {
    let number: Int
    let done: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette.of(scheme)
        ZStack {
            Circle().fill(done ? palette.good : .clear)
            Circle().stroke(done ? Color.clear : palette.fieldBorder, lineWidth: 1)
            if done {
                Text("\u{2713}").font(.ui(10, .bold)).foregroundStyle(.white)
            } else {
                Text("\(number)").font(.ui(10)).foregroundStyle(palette.text2)
            }
        }
        .frame(width: 16, height: 16).padding(.top, 1)
        .accessibilityElement()
        .accessibilityLabel(done ? "Step \(number), done" : "Step \(number)")
    }
}

/// The Remove sheet: names what stays, asks for the label typed back.
struct RemoveSheetContent: View {
    @Binding var draft: RemoveDraft
    let canConfirm: Bool
    var busy = false
    let actions: RemoveSheetActions

    @Environment(\.colorScheme) private var scheme
    @Environment(\.flatMaterials) private var flat

    private var palette: Palette { Palette.of(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TileIcon().frame(width: 22, height: 22)
                Text("Remove \"\(draft.label)\"?").font(.ui(13, .semibold))
                Spacer(minLength: 0)
            }
            .padding(.bottom, 9)
            Text(draft.text).font(.ui(12)).foregroundStyle(palette.text2)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            HStack(spacing: 8) {
                Text("Type the label to confirm").font(.ui(12)).foregroundStyle(palette.text2)
                if flat {
                    FieldBox { Text(draft.typed).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    FieldBox {
                        TextField("Label", text: $draft.typed).textFieldStyle(.plain)
                            .disabled(busy)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Type the label to confirm")
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // Cancel while `remove` runs would hide a remove that still finishes.
                ChromeButton(title: "Cancel", enabled: !busy, action: actions.cancel)
                ChromeButton(
                    title: "Remove", style: .danger, enabled: canConfirm && !busy,
                    action: actions.confirm)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        .frame(width: 418)
        .background(palette.winBg)
        .foregroundStyle(palette.text1)
    }
}

struct RemoveSheetActions {
    var cancel: () -> Void = {}
    var confirm: () -> Void = {}
}
