import CoreMedia
import CoreVideo

/// One `420v` frame off the stream. `@unchecked Sendable` for the CVPixelBuffer: delivered once, handed to VideoToolbox, never touched again. ``CursorOverlay/redraw(_:)`` keeps its own buffer because ScreenCaptureKit reuses this pool.
struct CapturedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    /// Invalid when the stream reported none; the encoder substitutes one frame interval.
    let duration: CMTime
    let geometry: FrameGeometry
}
