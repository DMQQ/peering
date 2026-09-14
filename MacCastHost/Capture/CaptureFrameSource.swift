import Foundation
import ScreenCaptureKit

/// What the pipeline needs from whatever is producing frames for it.
///
/// There are two implementations — ``CaptureEngine``, which wraps an `SCStream`, and
/// ``SyntheticCaptureEngine``, which generates its frames — and the protocol is shaped
/// around the pipeline's needs rather than around `SCStream`. That is the whole reason it
/// exists: the pipeline has to be runnable on a machine that has never been granted Screen
/// Recording, and a protocol whose `start` demands an `SCContentFilter` cannot be
/// implemented by a source that has none. Hence ``CaptureStartRequest`` — a description of
/// what is being started, which each backend interprets — rather than two methods, each of
/// which one of the backends would have to stub out.
///
/// The two implementations are not interchangeable in what they produce, only in the shape
/// they present: a real stream goes idle when nothing on screen moves, a generated one
/// never does.
protocol CaptureFrameSource: Sendable {
    /// Frames the source has handed out, and samples that carried no picture. See
    /// ``CaptureEngine/Statistics``.
    var statistics: CaptureEngine.Statistics { get }

    /// Called for every frame that carries an image, on the source's own queue.
    var onFrame: (@Sendable (CapturedFrame) -> Void)? { get set }

    /// Called when the source stops by itself — a stream that the system tore down, or a
    /// revoked permission. Never called for a stop the caller asked for.
    var onStop: (@Sendable (CaptureError) -> Void)? { get set }

    /// Starts producing frames. Returns once frames may begin arriving.
    func start(_ request: CaptureStartRequest) async throws

    /// Stops producing frames. Nothing is delivered after this returns.
    func stop() async
}

/// Everything a frame source can be asked to start.
///
/// The cases carry what their backend needs and nothing else. `.stream` is a real
/// `SCStream`, which cannot be built without a filter and a configuration — and both of
/// those require the catalogue to have been read, which requires Screen Recording
/// permission. `.synthetic` is the other end of that: a source that was built knowing its
/// own size and frame rate, and needs to be handed nothing at all.
///
/// `@unchecked Sendable` because `SCContentFilter` and `SCStreamConfiguration` come from a
/// module with no `Sendable` annotations. The value is built and consumed on one task, by
/// one call, and never shared.
enum CaptureStartRequest: @unchecked Sendable {
    case stream(filter: SCContentFilter, configuration: SCStreamConfiguration)
    case synthetic
}
