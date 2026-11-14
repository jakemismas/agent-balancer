import Core
import SwiftUI

struct PanelActions {
    var refresh: () -> Void = {}
    var toggleLogin: () -> Void = {}
    var quit: () -> Void = {}
    var copy: (String) -> Void = { _ in }
    /// Called before the Manage accounts window opens, with the account to show or nil.
    var manage: (String?) -> Void = { _ in }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The popover content: header, next launch, rows and actions. It caps at the visible screen
/// height minus 40 points and scrolls inside.
struct PanelView: View {
    let screen: MenuScreen
    let refreshState: RefreshState
    let loginItemOn: Bool
    let loginItemError: String?
    let actions: PanelActions
    var stepsOpen: Set<String> = []
    /// A fixed height cap for the render tool; the app reads the screen.
    var heightCap: CGFloat?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.flatMaterials) private var flat
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat = 0

    private var palette: Palette { Palette.of(scheme) }

    private var cap: CGFloat {
        if let heightCap { return heightCap }
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return screenHeight - 40
    }

    var body: some View {
        if flat {
            // ImageRenderer draws a scroll view empty, so the render tool shows the content whole.
            content.frame(width: 404).background(panelBackground)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                content
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: ContentHeight.self, value: g.size.height)
                        })
            }
            .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
            .frame(width: 404, height: contentHeight > 0 ? min(contentHeight, cap) : nil)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 13).fill(palette.flatPanel)
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(palette.panelBorder, lineWidth: 0.5))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch refreshState {
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    Text("Refreshing...").font(.ui(11)).foregroundStyle(palette.text2)
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
            case .failed(let text):
                Text(text).font(.ui(11)).foregroundStyle(palette.crit)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
            switch screen {
            case .accounts(let a):
                if let banner = a.banner {
                    BannerView(model: banner, palette: palette, copy: actions.copy)
                }
                if let next = a.next { NextCard(model: next, palette: palette) }
                separator
                VStack(spacing: 0) {
                    ForEach(a.rows) { row in
                        RowView(
                            model: row, palette: palette, copy: actions.copy,
                            stepsOpen: stepsOpen.contains(row.label),
                            manage: { label in
                                actions.manage(label)
                                ManageWindowGate.requested = true
                                openWindow(id: ManageWindowID.value)
                            })
                    }
                }
            case .card(let card):
                CardView(model: card, palette: palette, copy: actions.copy)
            }
            separator
            actionList
        }
        .padding(.top, 10).padding(.horizontal, 6).padding(.bottom, 6)
    }

    private var separator: some View {
        Rectangle().fill(palette.sep).frame(height: 1).padding(.horizontal, 10).padding(
            .vertical, 6)
    }

    private var updatedText: String? {
        if case .accounts(let a) = screen { return a.updatedText }
        return nil
    }

    private var header: some View {
        HStack(spacing: 9) {
            TileIcon().frame(width: 27, height: 27)
            Text("agent-balancer").font(.ui(13, .semibold))
                .foregroundStyle(palette.text1)
            Spacer(minLength: 0)
            if let updated = updatedText {
                Text(updated).font(.ui(11)).foregroundStyle(palette.text3)
            }
            Button(action: actions.refresh) {
                Image(systemName: "arrow.clockwise").font(.ui(12, .semibold))
                    .foregroundStyle(palette.text2).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain).help("Refresh now").accessibilityLabel("Refresh now")
        }
        .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 8)
    }

    private var actionList: some View {
        VStack(spacing: 0) {
            ActionRow(
                title: "Refresh now", shortcut: "\u{2318}R", palette: palette, key: "r",
                action: actions.refresh)
            ActionRow(
                title: "Manage accounts\u{2026}", shortcut: "\u{2318},", palette: palette,
                key: ",",
                action: {
                    actions.manage(nil)
                    ManageWindowGate.requested = true
                    openWindow(id: ManageWindowID.value)
                })
            ActionRow(
                title: "Open usage page", shortcut: "\u{2197}", palette: palette,
                action: { openURL(UsagePage.url) })
            separator
            ActionRow(
                title: "Open at login", shortcut: loginItemOn ? "\u{2713}" : "", palette: palette,
                checked: loginItemOn, action: actions.toggleLogin)
            if let loginItemError {
                Text(loginItemError).font(.ui(11)).foregroundStyle(palette.crit)
                    .padding(.horizontal, 10).padding(.vertical, 2)
            }
            ActionRow(
                title: "Quit agent-balancer", shortcut: "\u{2318}Q", palette: palette, key: "q",
                action: actions.quit)
        }
    }
}

struct ActionRow: View {
    let title: String
    let shortcut: String
    let palette: Palette
    var checked: Bool?
    var key: KeyEquivalent?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if let key {
            row.keyboardShortcut(key, modifiers: .command)
        } else {
            row
        }
    }

    private var row: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.ui(13))
                Spacer(minLength: 0)
                Text(shortcut).font(.ui(12))
                    .foregroundStyle(hovering ? Color.white.opacity(0.85) : palette.text3)
            }
            .foregroundStyle(hovering ? Color.white : palette.text1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? palette.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(checked == true ? .isSelected : [])
    }
}

struct NextCard: View {
    let model: NextModel
    let palette: Palette

    private func block(_ key: String, _ label: String, _ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(key).font(.ui(11)).foregroundStyle(palette.text2)
                    .frame(width: 74, alignment: .leading)
                Text(label).font(.ui(13, .semibold)).foregroundStyle(
                    palette.text1)
            }
            Text(reason).font(.ui(11)).foregroundStyle(palette.text2)
                .padding(.leading, 80).fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            block("Next launch", model.allLabel, model.allReason)
            block("Next Fable", model.fableLabel, model.fableReason)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(palette.nextBg))
        .padding(.horizontal, 6).padding(.bottom, 6)
    }
}

struct BannerView: View {
    let model: BannerModel
    let palette: Palette
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                WarnTriangle(color: palette.crit).frame(width: 11, height: 10).padding(.top, 2)
                Text(model.text).font(.ui(11.5)).foregroundStyle(palette.text1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = model.command {
                HStack(spacing: 8) {
                    Text(command).font(.ui(11, mono: true))
                        .foregroundStyle(palette.text1).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(palette.cardBg))
                    Spacer(minLength: 0)
                    CopyButton(text: command, palette: palette, copy: copy)
                }
                .padding(.leading, 19)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(palette.errBg))
        .padding(.horizontal, 6).padding(.bottom, 6)
    }
}

struct CardView: View {
    let model: CardModel
    let palette: Palette
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title).font(.ui(13, .semibold)).foregroundStyle(
                palette.text1)
            Text(model.text).font(.ui(11.5)).foregroundStyle(palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.lines, id: \.self) { line in
                Text(line).font(.ui(11, mono: true)).foregroundStyle(
                    palette.text1
                )
                .textSelection(.enabled)
            }
            if let command = model.command {
                HStack(spacing: 8) {
                    Text(command).font(.ui(11, mono: true))
                        .foregroundStyle(palette.text1).textSelection(.enabled)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(palette.cardBg))
                    Spacer(minLength: 0)
                    CopyButton(text: command, palette: palette, copy: copy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(palette.nextBg))
        .padding(.horizontal, 6).padding(.bottom, 4)
    }
}
