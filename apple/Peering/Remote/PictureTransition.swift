import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

struct HeroCarry: Equatable {
    /// **The direction decides whether anything is hidden.** Going out, the frozen snapshot is the
    /// arrangement and the window is a piece of it: the rest of it has to be hidden while that piece
    /// grows, or every other window grows across the screen with it. Coming back, the frozen snapshot
    /// is the window alone, a scrim there would black out the arrangement fading in behind it.
    let carriesOutOfArrangement: Bool
    let frozenAnchor: NormalizedRect
    let frozenSize: CGSize
}

struct PictureTransition {
    let token: UUID
    let targetSourceID: String?

    var zoom: CGFloat
    var pan: CGSize
    let startZoom: CGFloat
    let startPan: CGSize
    let endZoom: CGFloat
    let endPan: CGSize
    let startedAt: ContinuousClock.Instant
    var task: Task<Void, Never>?

    var settled: Bool

    var carry: HeroCarry?
}
