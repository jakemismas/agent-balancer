import Core
import SwiftUI

/// What the Manage accounts views can ask for. The window root fills these from the view model.
struct ManageActions {
    var copy: (String) -> Void = { _ in }
    var select: (String) -> Void = { _ in }
    var openAdd: () -> Void = {}
    var openRemove: () -> Void = {}
    var signIn: () -> Void = {}
    var changeEnds: (EndChoice) -> Void = { _ in }
    /// Each date the end date picker reports while it is edited; nothing runs yet.
    var stepEndDate: (String) -> Void = { _ in }
    /// The end of that edit, which runs one command for the last date.
    var finishEndDate: () -> Void = {}
}

enum ChromeStyle { case normal, primary, danger }

/// A push button in the look of design/render.html.
struct ChromeButton: View {
    let title: String
    var style: ChromeStyle = .normal
    var small = false
    var enabled = true
    var accessibility: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var palette: Palette { Palette.of(scheme) }

    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(small ? 11 : 12))
                .foregroundStyle(ink)
                .padding(.horizontal, small ? 8 : 11).padding(.vertical, small ? 1 : 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(
                        style == .primary ? Color.clear : palette.fieldBorder, lineWidth: 0.5)
                )
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibility ?? title)
    }

    private var fill: Color { style == .primary ? palette.accent : palette.btnBg }

    private var ink: Color {
        switch style {
        case .normal: return palette.text1
        case .primary: return .white
        case .danger: return palette.crit
        }
    }
}

struct RadioDot: View {
    let on: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette.of(scheme)
        ZStack {
            Circle().fill(on ? palette.accent : palette.fieldBg)
            Circle().stroke(on ? palette.accent : palette.fieldBorder, lineWidth: 1)
            if on { Circle().fill(.white).frame(width: 5.5, height: 5.5) }
        }
        .frame(width: 13, height: 13)
    }
}

/// One radio choice: a dot and a label, a button for the keyboard and VoiceOver.
struct RadioRow<Trailing: View>: View {
    let title: String
    let on: Bool
    var enabled = true
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 7) {
            Button(action: action) {
                HStack(spacing: 7) {
                    RadioDot(on: on)
                    Text(title).font(.ui(13)).foregroundStyle(Palette.of(scheme).text1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!enabled)
            .accessibilityLabel(title)
            .accessibilityAddTraits(on ? .isSelected : [])
            trailing
        }
        .padding(.vertical, 2)
    }
}

extension RadioRow where Trailing == EmptyView {
    init(title: String, on: Bool, enabled: Bool = true, action: @escaping () -> Void) {
        self.init(title: title, on: on, enabled: enabled, action: action) { EmptyView() }
    }
}

/// A command in a mono field with a Copy button. With `fill` the field takes the line's width.
struct CommandField: View {
    let command: String
    var fill = false
    let copy: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette.of(scheme)
        HStack(spacing: 8) {
            Text(command).font(.ui(11, mono: true)).foregroundStyle(palette.text1)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(palette.fieldBg))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).stroke(palette.fieldBorder, lineWidth: 0.5))
            CopyChip(text: command, what: "command", copy: copy)
        }
    }
}

/// A small Copy button that says "Copied" for a moment. VoiceOver hears what it copies.
struct CopyChip: View {
    let text: String
    /// What the chip copies, such as "command" or "folder path".
    let what: String
    let copy: (String) -> Void
    @State private var copied = false

    var body: some View {
        ChromeButton(
            title: copied ? "Copied" : "Copy", small: true, accessibility: "Copy \(what)"
        ) {
            copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}

struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette.of(scheme)
        content
            .font(.ui(12)).foregroundStyle(palette.text1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(palette.fieldBg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.fieldBorder, lineWidth: 0.5))
    }
}

struct SmallBadge: View {
    let text: String
    let main: Bool
    var selected = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette.of(scheme)
        Text(text.uppercased()).font(.ui(10, .semibold)).tracking(0.2)
            .foregroundStyle(selected ? .white : (main ? palette.badgeMainInk : palette.text2))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5).fill(
                    selected
                        ? Color.white.opacity(0.22) : (main ? palette.badgeMainBg : palette.badgeBg)
                ))
    }
}
