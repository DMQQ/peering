import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import os

let overlayLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A larger pointer drawn into the picture: ScreenCaptureKit offers only show/hide cursor switches with no size.
/// The stream leaves the system pointer visible (its movement keeps frames coming on a quiet desktop) and this opaque shape covers it at the same tip.
/// Luma plane only (frames are 420v). The values are 16 and 235, not 0 and 255: video range, and out-of-range luma is not clamped on the way through. Nothing allocates per frame.
/// The synthetic pipeline cannot use this: generated frames describe no screen. See CapturePipeline/ingest(_:).
final class CursorOverlay: @unchecked Sendable {
    enum Size: String, CaseIterable, Sendable {
        case small
        case medium
        case large

        var fractionOfHeight: CGFloat {
            switch self {
            case .small: return 0.032   // roughly twice the system's pointer
            case .medium: return 0.048  // roughly three times
            case .large: return 0.064   // roughly four times
            }
        }
    }

    static let ink: UInt8 = 235
    static let edge: UInt8 = 16

    /// Half is stroked outside the outline and half under the fill, so the visible edge is thinner. Scales with the pointer so the separator holds at any size.
    static let edgeWidth: CGFloat = 0.09

    /// A polygon, not a bitmap of the system cursor: its one-pixel steps become a staircase when scaled up.
    static let outline: [CGPoint] = [
        CGPoint(x: 0.000, y: 0.000),  // the tip, which is where the pointer is
        CGPoint(x: 0.000, y: 0.707),  // down the left edge, which is vertical
        CGPoint(x: 0.201, y: 0.512),  // up into the notch between the head and the tail
        CGPoint(x: 0.390, y: 0.963),  // down the tail's left side to its foot
        CGPoint(x: 0.549, y: 0.896),  // across the foot
        CGPoint(x: 0.360, y: 0.445),  // back up the tail's right side
        CGPoint(x: 0.622, y: 0.445),  // out to the head's bottom right corner
    ]

    struct Pass {
        let range: Range<Int>
        let value: UInt8
    }

    let lock = NSLock()

    /// Each closed by repeating its first point. Edge quads first and the outline last: the fill covers the inner half of its own edge.
    let vertices: [CGPoint]
    let passes: [Pass]

    var intersections = [CGFloat](repeating: 0, count: 16)

    var reportedRefusal = false

    /// Nil whenever no frame carries a pointer; rounding to the pixel keeps an idle sample from earning a frame unless the tip moved.
    var drawnTip: CGPoint?

    /// An idle sample need not say, and the screen has not changed since a frame that did. See redraw(_:).
    var lastTransform: InputTransform?

    var scratch: Scratch?

    var enabled: Bool
    var chosenSize: Size

    init(isEnabled: Bool = true, size: Size = .medium) {
        self.enabled = isEnabled
        self.chosenSize = size
        (self.vertices, self.passes) = Self.shape()
    }

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    var size: Size {
        get { lock.withLock { chosenSize } }
        set { lock.withLock { chosenSize = newValue } }
    }





}
