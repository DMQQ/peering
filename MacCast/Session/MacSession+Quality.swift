import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import os

extension MacSession {
    var autoQualityPath: AutoQualityPolicy.Path {
        switch connectionPath {
        case .lan: return .lan
        case .relay: return .relay
        case .direct, nil: return .direct
        }
    }

    /// Uncapped on the direct path for every plan: two devices on one network spend nobody's bandwidth. A relayed session is the operator's link, and ``PlanCapability/highBitrate`` buys 20 Mbps there instead of 8.
    var videoCeiling: AutoQualityPolicy.Tier {
        guard autoQualityPath == .relay else { return .high }
        return model.storeManager.access.includes(.highBitrate) ? .high : .medium
    }

    /// Turning manual on lands on the level picked last or the policy's current rate, so the picture does not jump.
    func setAutomaticQuality(_ automatic: Bool) {
        setStreamQuality(automatic ? .auto : (model.lastManualQuality ?? StreamQuality(autoQualityPolicy.tier)))
    }

    /// The save makes the Settings row and this one the same setting.
    func setStreamQuality(_ quality: StreamQuality) {
        // The one rung a plan can be short of, only while bytes are carried. Asking opens the plans rather than being quietly capped, since a silently soft picture reads as broken. High on a direct session is not gated: see ``videoCeiling``.
        if quality == .high, videoCeiling == .medium {
            model.paywallReason = .feature(.highBitrate)
            return
        }
        model.rememberQualityChoice(quality)
        if let bitrateKbps = quality.bitrateKbps {
            send(.setStreamQuality(fps: 0, bitrateKbps: min(bitrateKbps, videoCeiling.bitrateKbps)))
        } else {
            autoQualityPolicy = AutoQualityPolicy(path: autoQualityPath, ceiling: videoCeiling)
            lastAutoDroppedFrames = renderer.currentSnapshot.framesDropped
            send(.setStreamQuality(fps: 0, bitrateKbps: autoQualityPolicy.tier.bitrateKbps))
        }
    }

    /// Every arrival, not only an automatic one: the Mac clears `requestedBitrateKbps` when the video peer closes and falls back to its top rate, so an unsent manual level leaves the phone reading Low while watching 20 Mbps. The stored token is read, not ``SessionModel/streamQuality``, which Settings can leave stale.
    func applyInitialQuality() {
        let quality = SessionModel.storedQuality
        model.streamQuality = quality

        autoQualityPolicy = AutoQualityPolicy(path: autoQualityPath, ceiling: videoCeiling)
        lastAutoDroppedFrames = 0

        if let bitrateKbps = quality.bitrateKbps {
            model.lastManualQuality = quality
            send(.setStreamQuality(fps: 0, bitrateKbps: min(bitrateKbps, videoCeiling.bitrateKbps)))
        } else {
            send(.setStreamQuality(fps: 0, bitrateKbps: autoQualityPolicy.tier.bitrateKbps))
        }
    }

    func updateAutoQuality(from snapshot: VideoRenderer.Snapshot) {
        guard model.streamQuality == .auto, let latencyMilliseconds else {
            lastAutoDroppedFrames = snapshot.framesDropped
            return
        }

        // On the control channel the host holds the rate down on purpose, so asking for more would break its ceiling: see ``VideoCoordinator/effectiveBitrateKbps``. This end stops driving the number but still measures.
        guard videoTransport == .primary else {
            lastAutoDroppedFrames = snapshot.framesDropped
            return
        }

        let newDrops = snapshot.framesDropped >= lastAutoDroppedFrames
            ? snapshot.framesDropped - lastAutoDroppedFrames
            : 0
        lastAutoDroppedFrames = snapshot.framesDropped

        guard let tier = autoQualityPolicy.observe(
            latencyMilliseconds: latencyMilliseconds,
            newDroppedFrames: newDrops
        ) else { return }
        send(.setStreamQuality(fps: 0, bitrateKbps: tier.bitrateKbps))
        append(note: String(localized: "Auto quality changed to \(tier.bitrateKbps / 1_000) Mbps"))
    }
}
