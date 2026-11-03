import PeeringKit
import RemoteCore
import SwiftUI

struct PulseDot: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            LiveTimeline { context in
                let wave = (sin(context.date.timeIntervalSinceReferenceDate * 5) + 1) / 2
                content.opacity(0.4 + 0.6 * wave).scaleEffect(0.85 + 0.3 * wave)
            }
        } else {
            content
        }
    }
}
