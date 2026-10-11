import SwiftUI

enum GuideStepState { case done, current, pending }

/// One step of the pairing: a marker joined to the next by a line, with the step's own controls under its title only while it is the one in play.
struct GuideStepRow<Content: View>: View {
    let number: Int
    let state: GuideStepState
    let title: String
    var isLast = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                marker
                if !isLast {
                    Rectangle()
                        .fill(.white.opacity(state == .done ? 0.35 : 0.12))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(state == .pending ? Color.secondary : ColorPalette.ink)
                    .frame(minHeight: 30, alignment: .leading)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, isLast ? 0 : 24)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var marker: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ColorPalette.onInk)
                .frame(width: 30, height: 30)
                .background(ColorPalette.ink, in: Circle())
        case .current:
            Text("\(number)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 30, height: 30)
                .overlay { Circle().strokeBorder(ColorPalette.accent, lineWidth: 2) }
                .background(ColorPalette.accent.opacity(0.18), in: Circle())
        case .pending:
            Text("\(number)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
        }
    }
}
