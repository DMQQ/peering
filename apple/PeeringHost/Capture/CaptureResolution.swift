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

    var linearScale: Double {
        switch self {
        case .full: return 1
        case .threeQuarters: return 0.75
        case .half: return 0.5
        }
    }

    /// The nearest step, rounded so a scale just under a step does not cost a whole one.
    static func fitting(scale: Double) -> CaptureResolution {
        if scale >= 0.875 { return .full }
        return scale >= 0.625 ? .threeQuarters : .half
    }

    /// The smaller of two choices: the user's setting is a ceiling the rate can lower but never raise.
    func capped(by other: CaptureResolution) -> CaptureResolution {
        linearScale <= other.linearScale ? self : other
    }
}
