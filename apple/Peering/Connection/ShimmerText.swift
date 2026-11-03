import PeeringKit
import RemoteCore
import SwiftUI

/// Text with a slow light passing through it while the agent works: the line is alive, not just current.
struct ShimmerText: View {
    let text: String
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let label = Text(verbatim: text)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
        if active, !reduceMotion {
            label
                .foregroundStyle(.white.opacity(0.55))
                .overlay {
                    GeometryReader { geometry in
                        LiveTimeline { context in
                            let cycle = 2.4
                            let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                            LinearGradient(
                                colors: [.clear, .white, .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: geometry.size.width * 0.45)
                            .offset(x: (progress * 1.9 - 0.45) * geometry.size.width)
                        }
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
        } else {
            label.foregroundStyle(.white.opacity(0.8))
        }
    }
}
