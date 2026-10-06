import CoreMedia
import Foundation
import ScreenCaptureKit

/// A sample with no new picture. Its buffer, if any, is rewritten by the stream once the callback returns.
struct IdleSample: Sendable {
    let geometry: FrameGeometry
    /// May be invalid: a caller that needs a timestamp has to make one.
    let presentationTime: CMTime
    let duration: CMTime
}

/// What the pipeline needs from a frame producer: ``CaptureEngine`` or ``SyntheticCaptureEngine``.
/// A real stream goes idle when the screen is still, a generated one never does.
protocol CaptureFrameSource: Sendable {
    var statistics: CaptureEngine.Statistics { get }

    var onFrame: (@Sendable (CapturedFrame) -> Void)? { get set }

    /// Only ``CaptureEngine`` produces these.
    var onIdle: (@Sendable (IdleSample) -> Void)? { get set }

    /// Called when the source stops by itself. Never for a stop the caller asked for.
    var onStop: (@Sendable (CaptureError) -> Void)? { get set }

    func start(_ request: CaptureStartRequest) async throws

    func stop() async
}

/// `@unchecked Sendable`: `SCContentFilter` and `SCStreamConfiguration` carry no `Sendable` annotations.
enum CaptureStartRequest: @unchecked Sendable {
    case stream(filter: SCContentFilter, configuration: SCStreamConfiguration)
    case synthetic
    /// Several of the source's own streams composited into one canvas. Only ``MosaicCompositor`` takes this.
    case mosaic(MosaicPlan)
}
