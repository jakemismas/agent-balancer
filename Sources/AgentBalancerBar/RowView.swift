import Core
import SwiftUI

private struct Badge: View {
    let text: String
    let background: Color
    let ink: Color
    var warning = false

    var body: some View {
        HStack(spacing: 3) {
            if warning { WarnTriangle(color: ink).frame(width: 11, height: 10) }
            Text(text.uppercased()).font(.ui(10, .semibold)).tracking(0.2)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 5).fill(background))
    }
}

struct WarnTriangle: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 11
            let sy = size.height / 10
            var tri = Path()
            tri.move(to: CGPoint(x: 5.5 * sx, y: 0.8 * sy))
            tri.addLine(to: CGPoint(x: 10.3 * sx, y: 9.2 * sy))
            tri.addLine(to: CGPoint(x: 0.7 * sx, y: 9.2 * sy))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(color))
            ctx.fill(
                Path(
                    roundedRect: CGRect(x: 5 * sx, y: 3.6 * sy, width: 1 * sx, height: 3 * sy),
                    cornerRadius: 0.5),
                with: .color(.white))
            ctx.fill(
                Path(
                    ellipseIn: CGRect(x: 4.9 * sx, y: 7.1 * sy, width: 1.2 * sx, height: 1.2 * sy)),
                with: .color(.white))
        }
        .accessibilityHidden(true)
    }
}

/// A Copy button that says "Copied" for a moment.
struct CopyButton: View {
    let text: String
    let palette: Palette
    let copy: (String) -> Void
    @State private var copied = false

    var body: some View {
        Button {
            copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Text(copied ? "Copied" : "Copy")
                .font(.ui(11)).foregroundStyle(palette.text1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBg))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(palette.panelBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy command")
    }
}

struct RowView: View {
    let model: RowModel
    let palette: Palette
    let copy: (String) -> Void
    @State private var hovering = false
    let manage: ((String) -> Void)?
    @State private var showSteps: Bool

    init(
        model: RowModel, palette: Palette, copy: @escaping (String) -> Void,
        stepsOpen: Bool = false,
        manage: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.palette = palette
        self.copy = copy
        self.manage = manage
        _showSteps = State(initialValue: stepsOpen)
    }

    /// The dim of a stale row; the main badge stays out of it so its text keeps 4.5:1.
    private var dim: Double { model.dimmed ? 0.65 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(model.label).font(.ui(13, .semibold))
                    .foregroundStyle(palette.text1).opacity(dim)
                Badge(
                    text: model.roleBadge,
                    background: model.isMain ? palette.badgeMainBg : palette.badgeBg,
                    ink: model.isMain ? palette.badgeMainInk : palette.text2
                )
                .opacity(model.isMain ? 1 : dim)
                if let end = model.endBadge {
                    Badge(
                        text: end, background: palette.endsBg, ink: palette.warnInk, warning: true
                    )
                    .opacity(dim)
                }
                if let email = model.email {
                    Text(email).font(.ui(11)).foregroundStyle(palette.text2)
                        .lineLimit(1).truncationMode(.tail).padding(.leading, 2).opacity(dim)
                }
                Spacer(minLength: 0)
                if let inUse = model.inUseText {
                    HStack(spacing: 5) {
                        Circle().fill(palette.good).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(palette.good.opacity(0.18), lineWidth: 2))
                        Text(inUse).font(.ui(11)).foregroundStyle(palette.text2)
                    }
                    .fixedSize().opacity(dim)
                }
            }
            bodyView.opacity(dim)
            ForEach(Array(model.notes.enumerated()), id: \.offset) { _, note in
                Text(note.text).font(.ui(10.5))
                    .foregroundStyle(note.style == .warning ? palette.warnInk : palette.text3)
                    .padding(.top, 3).padding(.leading, 72).opacity(dim)
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 9)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(hovering ? palette.hover : .clear).opacity(dim)
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var bodyView: some View {
        switch model.body {
        case .meters(let m):
            MeterLine(model: m.all, palette: palette).padding(.top, 4)
            if let f = m.fable {
                MeterLine(model: f, palette: palette, help: MenuTips.fableMeter).padding(.top, 4)
            }
            if let reset = m.resetText {
                Text(reset).font(.ui(10.5)).foregroundStyle(palette.text3)
                    .padding(.top, 4).padding(.leading, 72)
            }
        case .note(let text):
            Text(text).font(.ui(11)).foregroundStyle(palette.text2).padding(.top, 4)
        case .error(let e):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    WarnTriangle(color: palette.crit).frame(width: 11, height: 10).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.ui(11.5, .semibold))
                            .foregroundStyle(palette.crit)
                        Text(e.text).font(.ui(11.5)).foregroundStyle(palette.text1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(showSteps ? "Hide steps" : "Show steps") { showSteps.toggle() }
                        .buttonStyle(.plain).font(.ui(11)).foregroundStyle(palette.text1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBg))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6).stroke(
                                palette.panelBorder, lineWidth: 0.5)
                        )
                        .fixedSize()
                }
                if showSteps {
                    StepsView(steps: e.steps, palette: palette, copy: copy)
                    if e.manageable, let manage {
                        Button("Open Manage accounts") { manage(model.label) }
                            .buttonStyle(.plain).font(.ui(11)).foregroundStyle(palette.text1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBg))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6).stroke(
                                    palette.panelBorder, lineWidth: 0.5)
                            )
                            .padding(.leading, 19)
                    }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.errBg))
            .padding(.top, 4)
        }
    }
}

struct StepsView: View {
    let steps: StepsModel
    let palette: Palette
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.steps.enumerated()), id: \.offset) { i, step in
                Text("\(i + 1). \(step)").font(.ui(11)).foregroundStyle(palette.text1)
            }
            if let command = steps.command {
                HStack(spacing: 8) {
                    Text(command).font(.ui(11, mono: true))
                        .foregroundStyle(palette.text1).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(palette.cardBg))
                    Spacer(minLength: 0)
                    CopyButton(text: command, palette: palette, copy: copy)
                }
            }
        }
        .padding(.leading, 19)
    }
}

struct MeterLine: View {
    let model: MeterModel
    let palette: Palette
    var help: String?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Text(model.name).font(.ui(11)).foregroundStyle(palette.text2)
                Spacer(minLength: 0)
            }
            .frame(width: 64, alignment: .leading)
            MeterBar(model: model, palette: palette)
            Text(model.valueText).font(.ui(11)).monospacedDigit()
                .foregroundStyle(isEstimate ? palette.text2 : palette.text1)
                .lineLimit(1).frame(width: 124, alignment: .trailing)
                .help(help ?? "")
        }
    }

    private var isEstimate: Bool {
        if case .estimate = model.kind { return true }
        return false
    }
}
