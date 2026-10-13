import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import RemoteCore
import os

extension VideoCoordinator {
    static var defaultSource: CaptureSource {
        .display(UInt32(CGMainDisplayID()))
    }

    func ensureCapturing() async throws {
        let target = lock.withLock { chosenSource ?? Self.defaultSource }
        let codecIsRight = pipeline.codec == desiredCodec()
        guard lock.withLock({ currentSource }) != target || !codecIsRight else { return }
        try await startCapture(target)
    }

/// Switches what is being captured.
    func switchSource(_ source: CaptureSource) async throws {
        let operation = lock.withLock { () -> Task<Void, Error> in
// Recorded before the switch, not after, so the intent is the client's even if the capture fails.
// Scheduling under the same lock also orders a disconnect after this switch, rather than letting its
// stop race the pipeline start.
            chosenSource = source
            let previous = lifecycleTail
            let operation = Task { [weak self] in
                if let previous { await previous.value }
                guard let self else { return }
                guard self.lock.withLock({ !self.audience.isIdle }) else { return }
                if self.lock.withLock({ self.currentSource }) == source {
                    self.pipeline.requestKeyframe()
                    self.onSourceChanged?(source)
                    return
                }
                try await self.startCapture(source)
            }
            lifecycleTail = Task { _ = await operation.result }
            return operation
        }

        do {
            try await operation.value
        } catch {
// The choice did not take, so it is not the client's any more: whatever is running stands, or nothing
// does, and the next client is not walked into retrying a source that has already failed once.
            lock.withLock { if chosenSource == source { chosenSource = currentSource } }
            throw error
        }
    }

    func startCapture(_ source: CaptureSource) async throws {
// Read here rather than when they were set: this is the one moment either of them can take effect.
// Read under one lock, so a pair the user changed while this was queued cannot be split across two
// streams.
        let (resolution, frameRate) = lock.withLock { (captureResolution, captureFrameRate) }
        // Before the start, because the description it holds belongs to the source being replaced:
        adapter.forget()
        pipeline.useCodec(desiredCodec())
        try await pipeline.start(
            source: source,
            frameRate: frameRate.rawValue,
            resolution: resolution
        )
        lock.withLock { currentSource = source }
        onSourceChanged?(source)
        armWatchdog(source: source)
        onStatus?("Capturing \(source.description)")
        coordinatorLog.notice("""
            capture started · \(source.description, privacy: .public) at \
            \(resolution.rawValue, privacy: .public) size \
            @ \(frameRate.rawValue, privacy: .public) fps
            """)
    }

    func armWatchdog(source: CaptureSource) {
        let item = DispatchWorkItem { [weak self] in
            self?.reportNoFrames(source: source)
        }
        let previous = lock.withLock { () -> DispatchWorkItem? in
            let old = watchdog
            watchdog = item
            return old
        }
        previous?.cancel()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.firstFrameGrace,
            execute: item
        )
    }

    func cancelWatchdog() {
        let item = lock.withLock { () -> DispatchWorkItem? in
            let current = watchdog
            watchdog = nil
            return current
        }
        item?.cancel()
    }

    func reportNoFrames(source: CaptureSource) {
        let stats = statistics
        let permission = CGPreflightScreenCaptureAccess()
        coordinatorLog.error("""
            capture produced no frames in \(Int(Self.firstFrameGrace), privacy: .public)s · \
            source \(source.description, privacy: .public) · \
            screen recording \(permission ? "granted" : "NOT granted", privacy: .public) · \
            stream delivered \(stats.framesDelivered, privacy: .public), \
            idle \(stats.idleSamples, privacy: .public)
            """)

// Frames that carry no picture are still frames, and a stream reporting them is working: it is
// delivering on schedule and the screen is not changing. The two counters together are what tell the
// difference, which is why ``CaptureEngine`` counts both.
        if stats.idleSamples > 0 && stats.framesDelivered == 0 {
            onStatus?("Capturing \(source.description) · nothing new to send yet")
            return
        }

        guard permission else {
            onFailure?(.screenRecordingDenied)
            return
        }

// Do not drop the window from the list: a stream that produces nothing is also what a minimised,
// hidden or off-Space window does, and those are ordinary states.

        onFailure?(.streamFailed(
            "Capture started but produced no frames from \(source.description), and Screen "
                + "Recording permission is granted. The source may have gone away."
        ))
    }
}

extension VideoCoordinator {
    func setDeclaredVideoCodecs(_ codecs: [String]?, clientKey: Data?) {
        guard let clientKey else { return }
        lock.withLock { declaredVideoCodecs[clientKey] = codecs }
    }

    /// The host's own codec, unless the client being served said it cannot decode it.
    func desiredCodec() -> VideoCodec {
        let declared = lock.withLock { audience.served?.peerPublicKey.flatMap { declaredVideoCodecs[$0] } }
        let chosen = RemoteCore.VideoCodec.negotiated(preferred: pipeline.preferredCodec.wireCodec, declared: declared)
        return chosen == .hevc ? .hevc : .h264
    }
}
