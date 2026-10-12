import CoreMedia
import CoreVideo
import Foundation
import MacCastKit
import RemoteCore
import ScreenCaptureKit
import os

extension CapturePipeline {
    func ingest(_ frame: CapturedFrame, source: CaptureSource) {
        guard lock.withLock({ self.source == source }) else { return }
        onGeometry?(frame.geometry)

        // The last point where the frame is still ours to draw on, and the only one holding both frame and geometry. Not on a mosaic: each tile's stream already has the real pointer drawn in by ScreenCaptureKit. See ``MosaicPlan``.
        if !isMosaic {
            overlay?.draw(into: frame.pixelBuffer, geometry: frame.geometry)
        }

        encode(frame, source: source)
    }

    /// Where pointer smoothness on a still screen comes from: the overlay turns pointer movement into a frame.
    /// ``onGeometry`` is not told about idle samples: their geometry can be emptier than a frame's and would overwrite a good one.
    func idle(_ sample: IdleSample, source: CaptureSource) {
        guard lock.withLock({ self.source == source }) else { return }
        guard Self.idleFramesEnabled else { return }
        guard let overlay, let frame = overlay.redraw(sample) else { return }
        encode(frame, source: source)
    }

    /// Off: on the device the rate collapses once the pointer is touched, because the first synthetic frame fails to decode and the renderer latches awaiting a keyframe. The fault is in what these frames are.
    static let idleFramesEnabled = false

    /// Shared with the idle path so both go through the resize check and keyframe bookkeeping.
    func encode(_ frame: CapturedFrame, source: CaptureSource) {
        // A resized window yields frames the old session cannot encode; rebuild on a size change only.
        let size = VideoEncoder.encodedSize(
            for: CGSize(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
        )

        let encoder: VideoEncoder
        let current = lock.withLock { self.encoder }
        // Not fed: it has reported its failure and is waiting to be replaced by the recovery.
        if let current, current.hasFailed { return }
        if let current, current.pixelSize == size {
            encoder = current
        } else {
            do {
                encoder = try rebuildEncoder(for: size, replacing: current, source: source)
            } catch {
                Analytics.failed(error, in: .capture)
                report(error as? CaptureError ?? .encodingFailed("\(error)"))
                return
            }
        }

        do {
            try encoder.encode(frame)
        } catch {
            report(error as? CaptureError ?? .encodingFailed("\(error)"))
        }
    }

    /// Capture queue only. Built for the surface's current size, not the configured one: at half resolution a grown window produces a full-size surface.
    func rebuildEncoder(
        for size: CGSize,
        replacing current: VideoEncoder?,
        source: CaptureSource
    ) throws -> VideoEncoder {
        let replacement = try VideoEncoder(
            codec: codec,
            pixelSize: size,
            frameRate: current?.frameRate ?? 60
        )
        replacement.onFrame = { [weak self] encoded in self?.deliver(encoded, source: source) }
        replacement.onFailure = { [weak self] error in self?.report(error) }

        // A new session owes a keyframe whether or not one was asked for.
        lock.withLock {
            encoder = replacement
            awaitsKeyframe = true
        }
// Shut down only after the swap, so nothing can hand a frame to a dead session.
        current?.shutdown()

        pipelineLog.notice("""
            capture surface resized to \(Int(size.width), privacy: .public)×\
            \(Int(size.height), privacy: .public) · encoder rebuilt
            """)
        return replacement
    }

    func deliver(_ encoded: EncodedFrame, source: CaptureSource) {
        guard lock.withLock({ self.source == source }) else { return }
        if encoded.isKeyframe {
            lock.withLock { awaitsKeyframe = false }
        }
        let consumer = lock.withLock { _onFrame }
        consumer?(encoded, source)
    }

    /// The coordinator decides what a stop means: most are rebuilt, a revoked permission shows an explanation.
    /// The log line is rate limited because a dead encoder reports from every frame it had in flight.
    func report(_ error: CaptureError) {
        let (failure, admission) = lock.withLock {
            (_onFailure, failureLogGate.admit(at: ProcessInfo.processInfo.systemUptime))
        }
        if case .log(let suppressed) = admission {
            let text = error.errorDescription ?? "unknown"
            pipelineLog.error("capture reported: \(text, privacy: .public) (\(suppressed, privacy: .public) similar held back)")
        }
        failure?(error)
    }
}
