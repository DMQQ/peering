import MacCastKit
import RemoteCore
import SwiftUI

struct RisingCard: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : 0.82, anchor: .bottom)
            .offset(y: phase.isIdentity ? 0 : 56)
            .blur(radius: phase.isIdentity ? 0 : 8)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}
