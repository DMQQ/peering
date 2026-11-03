import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    func animateBackToMosaic() {
        model.tileOpeningWatch?.cancel()

        let sourceID = model.activeSourceID
        guard let sourceID, let layout = model.mosaicLayout,
              let anchor = windowAnchor(in: layout, sourceID: sourceID),
              let target = mosaicReturnTransform(sourceID: sourceID)
        else {
            model.returnToMosaic()
            return
        }

        beginHeroTransition(
            to: CaptureSource.mosaic(layout).stableID,
            target: target,
            carry: HeroCarry(
                carriesOutOfArrangement: false,
                frozenAnchor: anchor,
                frozenSize: model.capturePixelSize ?? .zero
            )
        )

        model.returnToMosaic()
    }

    /// **The one animation in this app that moves a picture rather than the whole live layer.** The
    /// frozen layer's own content never changes for the life of this transition, so unlike the
    /// mosaic's first design there is nothing here for a decoder to race: the zoom and the pan are
    /// walked on a plain per-frame timer, same as any other view state, because nothing downstream
    /// of them is fighting a second writer on a different clock.
    @discardableResult
    func beginHeroTransition(
        to sourceID: String?,
        target: (zoom: CGFloat, pan: CGSize),
        carry: HeroCarry
    ) -> Task<Void, Never> {
        // **Nothing to animate over means no animation.** A freeze is the frame the live layer is
        // showing at this instant, so it cannot be the wrong tile or the wrong shape, but a layer
        // that has displayed nothing yet has nothing to give, and switching plainly is the honest
        // answer for a picture no one has seen.
        guard model.renderer.freezeCurrentFrame() else {
            return Task {}
        }

        let base = pictureBaseScale
        let start = (zoom: effectiveZoom, pan: pan)
        let end = (zoom: base * target.zoom, pan: target.pan)

        // The live layer's own resting state for whatever arrives. Safe to write immediately: it
        // is hidden behind the frozen layer for the whole of the transition, so nothing sees it
        // change.
        zoom = 1
        pan = .zero

        return startTransition(to: sourceID, from: start, to: end, carry: carry)
    }

    private func beginPlainTransition(to sourceID: String?, resetZoom: Bool) {
        // The same rule as a hero: no frozen picture, no transition. A cross-fade from an image
        // nobody froze would put an older picture on screen for the whole of it.
        guard model.renderer.freezeCurrentFrame() else { return }
        let current = (zoom: effectiveZoom, pan: pan)
        if resetZoom {
            zoom = 1
            pan = .zero
        }
        startTransition(to: sourceID, from: current, to: current, carry: nil)
    }

    @discardableResult
    private func startTransition(
        to sourceID: String?,
        from start: (zoom: CGFloat, pan: CGSize),
        to end: (zoom: CGFloat, pan: CGSize),
        carry: HeroCarry?
    ) -> Task<Void, Never> {
        transition?.task?.cancel()

        let startedAt = ContinuousClock().now
        let alreadySettled = start.zoom == end.zoom && start.pan == end.pan
        let token = UUID()
        // Fixed rather than the default: the `PictureTransition` below and every reader of
        // `transition?.token` after it have to agree on the same value, and generating a second
        // one there would make ``endTransitionIfReady()``'s comparisons meaningless.

        let task = Task { @MainActor in
            guard !alreadySettled else { return }
            let clock = ContinuousClock()
            while true {
                guard var current = transition, current.token == token else { return }
                let seconds = (clock.now - startedAt) / .seconds(1)
                let progress = Motion.settleProgress(at: seconds, response: Motion.pictureResponse)
                if seconds >= Motion.pictureResponse * 1.6 {
                    current.zoom = end.zoom
                    current.pan = end.pan
                    current.settled = true
                    if current.carry?.carriesOutOfArrangement == false,
                       let arrangement = model.renderer.mosaicSnapshot {
                        model.renderer.hold(arrangement)
                        let canvas = CGSize(
                            width: CGFloat(arrangement.width),
                            height: CGFloat(arrangement.height)
                        )
                        current.zoom = pictureScale.base(pixelSize: canvas, in: canvasSize)
                        current.pan = .zero
                    }
                    transition = current
                    endTransitionIfReady()
                    return
                }
                current.zoom = start.zoom + (end.zoom - start.zoom) * progress
                current.pan = CGSize(
                    width: start.pan.width + (end.pan.width - start.pan.width) * progress,
                    height: start.pan.height + (end.pan.height - start.pan.height) * progress
                )
                transition = current
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
            }
        }

        transition = PictureTransition(
            token: token,
            targetSourceID: sourceID,
            zoom: start.zoom, pan: start.pan,
            startZoom: start.zoom, startPan: start.pan,
            endZoom: end.zoom, endPan: end.pan,
            startedAt: startedAt, task: task,
            settled: alreadySettled,
            carry: carry
        )

        armTransitionDeadline(token: token)
        if alreadySettled { endTransitionIfReady() }
        return task
    }

    /// A transition that never ends leaves the picture frozen for good: the config it is waiting
    /// for can be lost to a network hiccup, or belong to a tile that never opens (though
    /// ``watchTileOpening(_:)`` already answers that one specifically, faster, by putting the
    /// arrangement back). This is the backstop for everything else, past the deadline, the live
    /// layer is shown wherever it currently is rather than left hidden behind a stale snapshot.
    private func armTransitionDeadline(token: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard transition?.token == token else { return }
            transition = nil
        }
    }

    func endTransitionIfReady() {
        guard let transition, transition.settled,
              model.picture?.sourceID == transition.targetSourceID,
              model.isReadyToPlace(of: model.capturePixelSize ?? .zero)
        else { return }
        self.transition = nil
    }

    /// Nothing for a picture a hero transition already targets, ``openMosaicTile(_:in:)`` and
    /// ``animateBackToMosaic()`` have already frozen the right snapshot and are animating it; this
    /// would only interrupt that with a second, motionless freeze of whatever is on screen at the
    /// moment the config happens to land.
    func reactToPictureChange(from previous: PictureIdentity, to current: PictureIdentity) {
        switch previous.change(to: current) {
        case .unchanged:
            return
        case .resized:
            // The magnification is kept, because it is a multiple of the fit, and a lane switch
            // has nothing to do with what the user was looking at. The offset is measured in
            // points of a canvas whose picture has just changed shape, so left alone it can sit
            // outside the range the new picture allows.
            pan = clampedPan(pan)
            guard transition?.targetSourceID != current.sourceID else {
                endTransitionIfReady()
                return
            }
            beginPlainTransition(to: current.sourceID, resetZoom: false)
        case .replaced:
            guard transition?.targetSourceID != current.sourceID else {
                endTransitionIfReady()
                return
            }
            beginPlainTransition(to: current.sourceID, resetZoom: true)
        }
    }

    func cancelTransition() {
        guard let transition else { return }
        transition.task?.cancel()
        self.transition = nil
    }

    /// **Called when the connection leaves `.ready`, because none of it survives the connection it
    /// was measuring.** This view is kept across a drop on purpose, the picture stays up, and the
    /// zoom and the open panel with it, but the transit state does not belong to the picture that
    /// comes back.
    func abandonPictureTransit() {
        cancelTransition()
        heldTile = nil
        targetTile = nil
        heldPoint = nil
    }
}
