import PeeringKit
import SwiftUI

extension HomeTab {
    /// One tap back to the chat or shell that was open last, on the Mac it lives on.
    @ViewBuilder
    var resumeCard: some View {
        if let activity = model.activityToResume {
            Button { model.resume(activity) } label: {
                HStack(spacing: 12) {
                    IconTile(
                        symbol: activity.kind == .chat ? "bubble.left.and.text.bubble.right" : "terminal",
                        size: 38
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pick up where you left off")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ColorPalette.ink)
                        Text("\(activity.title) on \(model.hostNames[activity.hostID] ?? String(localized: "your Mac"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("resume-last")
        }
    }
}
