import SwiftUI

/// What the Agents page holds while the Mac is still answering: a section label and three rows shaped like chat cards, so the page does not jump when the real ones arrive.
struct AgentsPagePlaceholder: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            VStack(alignment: .leading, spacing: 10) {
                bar(width: 70, height: 10, phase: phase)
                    .padding(.leading, 2)
                ForEach(0..<3, id: \.self) { index in
                    row(phase: phase - Double(index) * 0.08)
                }
            }
        }
        .padding(.top, 20)
        .accessibilityHidden(true)
    }

    private func row(phase: Double) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(shade(phase))
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 8) {
                bar(width: 150, height: 12, phase: phase)
                bar(width: 96, height: 9, phase: phase)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
    }

    private func bar(width: CGFloat, height: CGFloat, phase: Double) -> some View {
        Capsule()
            .fill(shade(phase))
            .frame(width: width, height: height)
    }

    /// A slow swell, not a sweep: one brightness for the whole row that drifts down the list.
    private func shade(_ phase: Double) -> Color {
        .white.opacity(0.06 + 0.06 * (0.5 + 0.5 * sin(phase * 2 * .pi)))
    }
}
