import CoreGraphics
import Foundation

/// Not `SCStreamConfiguration.captureResolution`, which stays `.nominal`: this is the size of the surface that comes out.
enum CaptureResolution: String, CaseIterable, Sendable {
    case full

    case threeQuarters

    case half

/// Half of what the stream would otherwise be built at, not half of `CGDisplayPixelsWide` (points: 1512×982 on a 3024×1964 panel).
/// Odd dimensions stay odd: the stream rounds to the nearest point and ``VideoEncoder`` rounds down to even, in that order. See ``CapturePipeline/encode(_:)``.
    func pixelSize(for native: CGSize) -> CGSize {
        switch self {
        case .full: return native
        case .threeQuarters: return CGSize(width: native.width * 0.75, height: native.height * 0.75)
        case .half: return CGSize(width: native.width / 2, height: native.height / 2)
        }
    }
}
