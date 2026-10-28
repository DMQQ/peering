import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import PeeringKit
import RemoteCore
import os

extension VideoCoordinator {
    func refreshSpacePreviews() {
        pipeline.refreshSpacePreviews()
    }

/// A source this Mac has been asked for and cannot capture, so the catalogue stops offering it.
    func markUncapturable(_ source: CaptureSource) {
        pipeline.markUncapturable(source)
    }

    func refreshSourceThumbnails() {
        pipeline.refreshSourceThumbnails()
    }

    func watchSourceThumbnails(_ watching: Bool) {
        pipeline.watchSourceThumbnails(watching)
    }

    func snapshot(maxWidth: Int) async -> CGImage? {
        await pipeline.snapshot(maxWidth: maxWidth)
    }

/// Applies a stream-quality change requested by the client.
    func setStreamQuality(fps: Int, bitrateKbps: Int) {
        if let framesPerSecond = StreamQualityLimits.clampedFramesPerSecond(fps) {
            pipeline.setFrameRateLimit(framesPerSecond)
        }
        guard let bitrateKbps = StreamQualityLimits.clampedBitrateKbps(bitrateKbps) else { return }
        lock.withLock { requestedBitrateKbps = bitrateKbps }
        pipeline.setBitrate(effectiveBitrateKbps * 1000)
    }

/// Moves video between the transport the client prefers and the control channel.
    func setVideoTransport(_ request: VideoTransportRequest, clientKey: Data?, controlPeer: PeerConnection) {
        let served = lock.withLock { audience.served }
        if let served, let clientKey, served.peerPublicKey != clientKey {
// Somebody else's picture. A session is served by one client at a time, and redirecting the stream to
// a second one on that client's say-so is the one thing the authorization check on a video connection
// exists to prevent.
            coordinatorLog.notice("refused a video transport request from a client that is not being served")
            return
        }
        guard served != nil else {
// Nothing to move. A client with no video peer at all is one whose video connection never arrived,
// which is a different failure with a different message already on its screen.
            coordinatorLog.notice("refused a video transport request: no video client is attached")
            return
        }

        switch request.transport {
        case .control:
            guard streamer.isProducing(within: Self.producingWindow) else {
// A still screen produces no frames at all, and neither does a capture that never started. Moving the
// stream in either case would cap the rate and change nothing else, so the request is declined and the
// client asks again shortly, by which time there is either a picture to move or nothing to move it for.
                coordinatorLog.notice("declined the control-channel fallback: nothing has been produced recently")
                return
            }
            guard streamer.use(transport: .control, controlPeer: controlPeer) else { return }
            lock.withLock { videoTransport = .control }
            pipeline.setBitrate(effectiveBitrateKbps * 1000)
            coordinatorLog.notice("video moved to the control channel · \(request.reason, privacy: .public)")

        case .primary:
            streamer.use(transport: .primary, controlPeer: nil)
            lock.withLock { videoTransport = .primary }
            pipeline.setBitrate(effectiveBitrateKbps * 1000)
            coordinatorLog.notice("video moved back to the transport the client prefers · \(request.reason, privacy: .public)")
        }
    }

/// Opens the relay's datagram path for a client that asked for it.
    func enableVideoDatagrams(clientKey: Data?, relay: RelaySession) -> Data? {
        let served = lock.withLock { audience.served }
        if let served, let clientKey, served.peerPublicKey != clientKey {
            coordinatorLog.notice("refused a video datagram request from a client that is not being served")
            return nil
        }
        guard served != nil else {
            coordinatorLog.notice("refused a video datagram request: no video client is attached")
            return nil
        }
        guard let secret = VideoKeySchedule.randomSecret() else {
            coordinatorLog.error("no secure random for a video secret; the picture stays on the control channel")
            return nil
        }

        do {
            let lane = try VideoDatagramLane(relay: relay, secret: secret)
            guard streamer.useDatagrams(lane) else { return nil }
            coordinatorLog.notice("video is going on the relay's datagram path")
            return secret
        } catch {
            Analytics.failed(error, in: .relay, context: ["operation": "open relay datagram lane"])
            coordinatorLog.error("could not open the relay's video datagram path: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Drops both halves of the choice above, for an audience that has ended or paused.
    /// Call with `lock` held.
    func forgetTransportChoiceLocked() {
        videoTransport = .primary
        requestedBitrateKbps = 0
        // Only takes leaf locks and enqueues, so nothing calls back into the coordinator.
        pipeline.setFrameRateLimit(nil)
    }

/// What the encoder should be running at: the client's choice, and the control channel's ceiling on top
/// of it.
    var effectiveBitrateKbps: Int {
        lock.withLock {
            let asked = requestedBitrateKbps > 0
                ? requestedBitrateKbps
                : VideoFallbackPolicy.preferredTransportBitrateKbps
            guard videoTransport == .control else { return asked }
            return min(asked, VideoFallbackPolicy.controlChannelBitrateKbps)
        }
    }

    /// How recently the encoder must have produced something for the host to believe that a
    /// missing picture is the network's doing rather than there being no picture.
    static let producingWindow: TimeInterval = 5

    func stop() {
// Before anything else: a teardown must not be reported as a failure to capture.
        cancelWatchdog()
        lock.withLock {
            currentSource = nil
            chosenSource = nil
            audience.removeAll()
            forgetTransportChoiceLocked()
            scheduleLifecycleLocked { [weak self, pipeline] in
                await pipeline.stop()
                guard let self else { return }
                self.adapter.forget()
                self.lock.withLock { self.currentSource = nil }
            }
        }
        streamer.detach()
        onSourceChanged?(nil)
        onInputTransform?(nil)
    }
}
