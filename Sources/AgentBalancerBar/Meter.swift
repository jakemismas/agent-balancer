import Core
import SwiftUI

/// A thin meter. A solid meter fills to the value; the estimate meter shows the free part as a
/// plain track and the part that may be used as a dashed span.
struct MeterBar: View {
    let model: MeterModel
    let palette: Palette

    private var fill: AnyShapeStyle {
        switch model.tone {
        case .normal: AnyShapeStyle(palette.barFill)
        case .warn: AnyShapeStyle(palette.warn)
        case .crit: AnyShapeStyle(palette.crit)
        }
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            switch model.kind {
            case .solid(let fraction):
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(palette.track)
                    RoundedRectangle(cornerRadius: 3).fill(fill)
                        .frame(width: w * min(1, max(0, fraction)))
                }
            case .estimate(let free, let possible):
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(palette.track, lineWidth: 1)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 3,
                            topTrailingRadius: 3
                        )
                        .fill(palette.track).frame(width: w * min(1, max(0, free)))
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(
                            palette.estimate, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                        )
                        .frame(width: w * min(1, max(0, possible)), height: 8)
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(model.accessibilityValue)
    }
}

/// The small question mark that explains a label on hover or keyboard focus.
struct TipMark: View {
    let text: String
    let palette: Palette

    var body: some View {
        Text("?")
            .font(.ui(9, .bold))
            .foregroundStyle(palette.text3)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(palette.text3, lineWidth: 1))
            .help(text)
            .accessibilityLabel("More info")
            .accessibilityHint(text)
    }
}
