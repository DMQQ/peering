import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import os

extension MacSession {
    /// Touches nothing else: the control channel, shells, clipboard and the keep-awake assertion all survive. Silent for a Mac that cannot take it.
    func setPicturePaused(_ paused: Bool) {
        guard PicturePause.mayAsk(hostDeclared: hostSupportsVideoPause) else { return }
        guard phase.holdsSession, paused != picturePaused else { return }
        picturePaused = paused
        send(.setVideoEnabled(!paused))

        if paused {
            pictureResumedAt = nil
            pictureResumeBaselineFrames = nil
        } else {
            // Taken before the frame arrives, the only moment it can be: the renderer's total when the ask went out is what the first frame back is measured from.
            pictureResumedAt = Date()
            pictureResumeBaselineFrames = renderer.currentSnapshot.framesEnqueued
            lastResumeMilliseconds = nil
        }
    }

    /// Called from the poll, not the event path, because the frame that answers may not touch the main actor. A count that moved in either direction counts: backwards is the renderer's total resetting.
    func measureResumeIfNeeded(_ snapshot: VideoRenderer.Snapshot) {
        guard let resumedAt = pictureResumedAt, let baseline = pictureResumeBaselineFrames else { return }
        guard snapshot.framesEnqueued != baseline else { return }

        pictureResumedAt = nil
        pictureResumeBaselineFrames = nil
        let milliseconds = Date().timeIntervalSince(resumedAt) * 1000
        lastResumeMilliseconds = milliseconds
        append(note: String(localized: "Picture back \(Int(milliseconds.rounded())) ms after asking for it"))
    }

    var activeSourceTitle: String? {
        // A mosaic is named before the catalogue is asked, since the catalogue has no row for it, and from the ask as well as the answer, so the pill names it as soon as it is asked for.
        if isAskingForMosaic, let layout = mosaicLayout {
            return String(localized: "\(layout.tiles.count) windows")
        }
        guard let activeSourceID,
              let descriptor = catalog?.all.first(where: { $0.id == activeSourceID })
        else { return nil }
        return descriptor.title
    }

    /// Answered from what the picture is rather than what was asked, so a mosaic the Mac refuses to build does not leave the arrangement unreachable; the ask counts too, so it is not offered while the canvas is being built.
    var canReturnToMosaic: Bool {
        mosaicLayout != nil && !isShowingMosaic && !isAskingForMosaic
    }

    /// The picture on screen, not the one being asked for: everything drawn over the picture is measured against this. ``picture`` first, the catalogue second. See ``capturePointSize``.
    var capturePixelSize: CGSize? {
        if let picture, picture.pixelSize.width > 0, picture.pixelSize.height > 0 {
            return picture.pixelSize
        }
        if let activeSourceID,
           let descriptor = catalog?.all.first(where: { $0.id == activeSourceID }),
           descriptor.pixelSize.width > 0, descriptor.pixelSize.height > 0 {
            return descriptor.pixelSize
        }
        if let first = catalog?.displays.first { return first.pixelSize }
        return nil
    }

    /// Halves the pixel size, assuming a 2x backing store: the protocol carries pixels, not the point-to-pixel scale. It only scales a relative nudge, so a wrong factor changes cursor speed, not where it lands.
    var capturePointSize: CGSize {
        guard let pixels = capturePixelSize else { return CGSize(width: 1512, height: 982) }
        return CGSize(width: pixels.width / 2, height: pixels.height / 2)
    }

    /// The catalogue is the only thing that says what a source is, so it decides whether one can change size on its own; a source with no entry is unknown. See ``PictureIdentity/change(to:)``.
    func pictureIdentity(of config: VideoStreamConfig) -> PictureIdentity {
        PictureIdentity.forStream(
            config,
            catalog: catalog,
            // The arrangement as well as its name: a mosaic has no catalogue row.
            source: askedMosaicLayout.map { CaptureSource.mosaic($0) }
        )
    }
}
