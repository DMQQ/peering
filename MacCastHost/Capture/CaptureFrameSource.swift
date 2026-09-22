import CoreMedia
import Foundation
import ScreenCaptureKit

/// A sample the stream delivered with no new picture in it.
///
/// **There is no picture in this, and there may be no buffer either.** `.idle` means the
/// display has not changed since the last frame. ScreenCaptureKit delivers these on schedule
/// whether or not anything happened, and nothing about one is a frame: it may carry no image
/// buffer at all, and one that does carry a buffer is a buffer the stream will write into
/// again the moment the callback returns. A frame drawn from those pixels would be drawn
/// from something that was never promised, and the failure would look like a picture that is
/// wrong rather than like a pointer that is missing.
///
/// What an idle sample is good for is the two things it does say — that the screen has not
/// changed, and where the captured content sits on it. The picture an idle frame is built
/// on is the overlay's own, kept from the last frame the stream actually delivered. This is
/// only what the overlay is told. See ``CursorOverlay/redraw(_:)``.
struct IdleSample: Sendable {
    /// Where the captured content sits on screen, exactly as a frame reports it. May be
    /// empty in the same way a frame's is: an idle sample says what it can.
    let geometry: FrameGeometry
    /// When the stream took this sample, on its own clock.
    ///
    /// **May be invalid, and that is not an error.** An idle sample is not a frame, and
    /// nothing requires it to say when it is — so a caller that needs a timestamp has to
    /// make one rather than assume this has one. See ``CursorOverlay/redraw(_:)``.
    let presentationTime: CMTime
    /// The stream's own duration for a frame at its rate, when it reports one.
    let duration: CMTime
}

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

    /// Called for every sample that carries no new picture, on the source's own queue.
    ///
    /// Only ``CaptureEngine`` ever produces these: a real stream reports on a schedule
    /// whether or not the screen changed, and a generated one always has something new to
    /// send. See ``IdleSample``.
    var onIdle: (@Sendable (IdleSample) -> Void)? { get set }

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
    /// Several streams of the source's own, composited into one canvas. See ``MosaicCompositor``,
    /// which is the only thing that takes this: it owns those streams rather than being handed
    /// one, which is why the plan is a value here and the engines are its business.
    case mosaic(MosaicPlan)
}
