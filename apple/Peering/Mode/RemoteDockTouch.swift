import PeeringKit
import SwiftUI

/// Where the finger is on the pad, and when the pointer last moved. A class of its own so the dock's body does not read it: a view that did was rebuilt on every sample of a 120 Hz drag, and the pointer stuttered behind it.
@Observable
final class RemoteDockTouch {
    var point: CGPoint?
    @ObservationIgnored var lastMoveAt = Date.distantPast
}

/// The only reader of the finger's position, so a move redraws the dots and nothing else.
struct RemoteDockTouchField: View {
    let touch: RemoteDockTouch
    let ripple: RemoteDockRipple?

    var body: some View {
        RemoteDockDotField(touch: touch.point, ripple: ripple)
    }
}

final class RemoteDockEngineBox {
    var engine = TrackpadEngine()
}
