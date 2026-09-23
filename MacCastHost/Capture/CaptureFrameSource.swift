import CoreMedia
import Foundation
import ScreenCaptureKit

/// A sample the stream delivered with no new picture in it.
///
/// Nothing about one is a frame. It may carry no image buffer at all, and one that does carry a
/// buffer is a buffer the stream writes into again the moment the callback returns. What an idle
/// sample does say is that the screen has not changed and where the captured content sits on it;
/// the picture an idle frame is built on is the overlay's own, kept from the last real frame.
/// See ``CursorOverlay/redraw(_:)``.
struct IdleSample: Sendable {
/// Where the captured content sits on screen, exactly as a frame reports it. May be empty, as a
/// frame's can be.
    let geometry: FrameGeometry
/// When the stream took this sample, on its own clock.
///
/// May be invalid: nothing requires an idle sample to say when it is, so a caller that needs a
/// timestamp has to make one. See ``CursorOverlay/redraw(_:)``.
    let presentationTime: CMTime
    /// The stream's own duration for a frame at its rate, when it reports one.
    let duration: CMTime
}

/// What the pipeline needs from whatever is producing frames for it.
///
/// Two implementations: ``CaptureEngine``, which wraps an `SCStream`, and
/// ``SyntheticCaptureEngine``. The protocol is shaped around the pipeline rather than around
/// `SCStream`, so the pipeline can run on a machine that has never been granted Screen Recording.
/// Hence ``CaptureStartRequest``, a description each backend interprets, rather than methods one
/// backend would have to stub out.
///
/// The two are not interchangeable in what they produce: a real stream goes idle when nothing on
/// screen moves, a generated one never does.
protocol CaptureFrameSource: Sendable {
    /// Frames the source has handed out, and samples that carried no picture. See
    /// ``CaptureEngine/Statistics``.
    var statistics: CaptureEngine.Statistics { get }

    /// Called for every frame that carries an image, on the source's own queue.
    var onFrame: (@Sendable (CapturedFrame) -> Void)? { get set }

/// Called for every sample that carries no new picture, on the source's own queue.
///
/// Only ``CaptureEngine`` produces these. See ``IdleSample``.
    var onIdle: (@Sendable (IdleSample) -> Void)? { get set }

    /// Called when the source stops by itself: a stream that the system tore down, or a
    /// revoked permission. Never called for a stop the caller asked for.
    var onStop: (@Sendable (CaptureError) -> Void)? { get set }

    /// Starts producing frames. Returns once frames may begin arriving.
    func start(_ request: CaptureStartRequest) async throws

    /// Stops producing frames. Nothing is delivered after this returns.
    func stop() async
}

/// Everything a frame source can be asked to start.
///
/// Each case carries what its backend needs and nothing else. `.synthetic` needs to be handed
/// nothing; `.stream` cannot be built before the catalogue is read, which needs Screen Recording.
///
/// `@unchecked Sendable` because `SCContentFilter` and `SCStreamConfiguration` come from a module
/// with no `Sendable` annotations. The value is built and consumed on one task, by one call.
enum CaptureStartRequest: @unchecked Sendable {
    case stream(filter: SCContentFilter, configuration: SCStreamConfiguration)
    case synthetic
/// Several streams of the source's own, composited into one canvas. Only ``MosaicCompositor``
/// takes this: it owns those streams rather than being handed one.
    case mosaic(MosaicPlan)
}
