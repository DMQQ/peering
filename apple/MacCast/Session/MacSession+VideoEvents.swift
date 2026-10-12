import MacCastKit
import RemoteCore
import SwiftUI

extension MacSession {
    func apply(video event: ClientSession.VideoEvent) {
        switch event {
        case .connecting:
            videoStatus = String(localized: "Opening the video channel…")
            isVideoStreaming = false
        case .config(let config):
            // The decoder half is done on the network queue where frames are handled, so it is ordered against them (see the event handler in `connect(to:)`): doing it here would reset after a keyframe from the same read and throw it away. Only the labels belong on the main actor.
            videoStatus = "\(config.codec.rawValue.uppercased()) \(config.pixelWidth)×\(config.pixelHeight)"
            isVideoStreaming = true
            // A picture has been sent to this attempt, which allows the relay handover; sticky because a config is. See ``MacSession/hasHadPicture``.
            hasHadPicture = true
            // Published, not acted on: the zoom and pan that answer to it live in the screen, and ``PictureIdentity`` is all it needs. A config describing the stream it already described leaves it equal.
            picture = pictureIdentity(of: config)
            // The renderer gets the source identity atomically with the config on its serial queue; setting it here raced the first frame.
            // Record the arrangement the picture is of here, because a config is the Mac answering the ask and the moment picture and this end's idea of it agree again. Not animated: borders travelling over a picture that has already changed read as rectangles shuffling on their own.
            // Recorded only when the config's canvas matches the ask as it was made (``MacSession/askedMosaicLayout``), not the one this end would build now: ``mosaicLayout`` is rebuilt from the live screen and catalogue, so recording it stored arrangements the Mac never built and overlays were mapped through a canvas that was not on screen. A picture that does not match leaves the record alone.
            if let asked = askedMosaicLayout,
               CaptureSource.mosaic(asked).stableID == config.sourceID {
                pictureMosaicLayout = asked
            } else if !config.sourceID.hasPrefix("mosaic:") {
                pictureMosaicLayout = nil
            }
            // Anything else leaves the record alone: the picture is still the last arrangement that answered, until the Mac catches up.
            append(note: "Video stream started: \(config.pixelWidth)×\(config.pixelHeight) \(config.codec.rawValue.uppercased())")
        case .frame:
            break // Handled on the network queue; see `connect(to:)`.
        case .transport(let transport):
            // The client's own decision, reported back: the picture looks the same on either lane but smaller on one, so without this the user guesses why the Mac looks soft.
            videoTransport = transport
            if transport == .control {
                append(note: String(localized: "The picture is coming over the control channel, at reduced quality."))
            } else {
                append(note: String(localized: "The picture is back on the direct video channel."))
            }
        case .ended(let reason):
            videoStatus = String(localized: "Video ended: \(reason)")
            isVideoStreaming = false
        }
    }

    func startVideoPolling() {
        videoPoll?.cancel()
        videoPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                // The one tick that outlives a dial: a dial that never answers ends nothing, and this stops the screen saying Reconnecting while the network is silent. See ``SessionModel/reconnectWindow``.
                giveUpAfterReconnectWindow()
                let snapshot = self.renderer.currentSnapshot
                if snapshot.hasConfig {
                    self.captureSessionBandwidth(snapshot)
                    self.updateFrameRate(from: snapshot)
                    self.updateAutoQuality(from: snapshot)
                    self.measureResumeIfNeeded(snapshot)

                    let framesLabel = String(localized: " · \(snapshot.framesEnqueued) frames")
                    let suffix = snapshot.framesDropped > 0 ? String(localized: " · \(snapshot.framesDropped) dropped") : ""
                    let waiting = snapshot.awaitingKeyframe ? String(localized: " · waiting for a keyframe") : ""
                    // Said here, not only in the notes: a reduced rate nothing on screen explains reads as a fault.
                    let lane = self.videoTransport == .control ? String(localized: " · sharing the control channel") : ""
                    // The rate leads: the question a choppy picture raises is frames per second, which only a difference between two samples answers.
                    let rate = self.videoFramesPerSecond > 0
                        ? String(localized: " · \(Int(self.videoFramesPerSecond.rounded())) fps")
                        : ""
                    self.videoStatus = "\(snapshot.codec.rawValue.uppercased()) \(snapshot.pixelWidth)×\(snapshot.pixelHeight)\(rate)\(framesLabel)\(suffix)\(waiting)\(lane)"
                }
            }
        }
    }

    /// Derived from two polls since neither end knows the other's rate. Smoothed heavily: a half-second window reads one late batch as a swing, and this is for telling thirty from sixty.
    func updateFrameRate(from snapshot: VideoRenderer.Snapshot) {
        let now = ContinuousClock.now
        defer { lastFrameSample = (snapshot.framesEnqueued, now) }

        guard let last = lastFrameSample else { return }
        // A count that went backwards is a reset, not a negative rate: the renderer drops its totals when the stream restarts.
        guard snapshot.framesEnqueued >= last.count else {
            videoFramesPerSecond = 0
            return
        }
        let span = last.at.duration(to: now)
        let elapsed = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
        guard elapsed > 0 else { return }

        let rate = Double(snapshot.framesEnqueued - last.count) / elapsed
        videoFramesPerSecond = videoFramesPerSecond == 0
            ? rate
            : videoFramesPerSecond * 0.6 + rate * 0.4
    }
}
