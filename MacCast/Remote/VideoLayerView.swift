import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import VideoToolbox
import os

struct VideoLayerView: UIViewRepresentable {
    let renderer: VideoRenderer
    /// The picture's size as this app believes it, for the trace only; the layer fits frames its own way and the trace compares the two.
    var pictureSize: CGSize = .zero
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    /// The still carries the transform the picture had before the change; the live layer takes the new one and fades in over it, so the same rectangle sharpens rather than jumps.
    var stillZoom: CGFloat = 1
    var stillPan: CGSize = .zero
    var showsStill = false

    var stillPicture: CGImage?

    var backdropPicture: CGImage?
    var backdropZoom: CGFloat = 1

    final class Coordinator {
        var showsStill = false
        var stillPicture: CGImage?
        var backdropPicture: CGImage?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        if let layer = view.displayView.displayLayer {
            renderer.attach(layer)
            // The display view, not the container, so PiP mirrors the layer actually holding the picture.
            SessionPiP.shared.attach(view.displayView)
        }
        // The still is not offered to PiP: it holds a frame from the previous session.
        return view
    }

    func updateUIView(_ view: VideoHostView, context: Context) {
        // Placement is a layer transform with implicit animation off: SwiftUI-applied offsets went through UIKit layout and got Core Animation's quarter-second implicit animation, so a pan trailed the finger.
        // Applied to the content view, not the hosted view (SwiftUI resizes it under any transform, see ``VideoHostView/contentView``) and not the display view (PiP mirrors its layer).
        let target = CGAffineTransform(translationX: pan.width, y: pan.height)
            .scaledBy(x: zoom, y: zoom)
        let stillTarget = CGAffineTransform(translationX: stillPan.width, y: stillPan.height)
            .scaledBy(x: stillZoom, y: stillZoom)

        // The hand-over is one commit: still takes the frozen picture, live layer takes the arriving transform, still takes the outgoing one, live is hidden, all in one disabled-actions transaction so no frame shows a mismatched pair.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if stillPicture !== context.coordinator.stillPicture {
            context.coordinator.stillPicture = stillPicture
            view.stillView.layer.contents = stillPicture
        }
        view.contentView.transform = target
        view.stillContentView.transform = stillTarget
        if backdropPicture !== context.coordinator.backdropPicture {
            context.coordinator.backdropPicture = backdropPicture
            view.backdropView.layer.contents = backdropPicture
        }
        view.backdropContentView.transform = CGAffineTransform(scaleX: backdropZoom, y: backdropZoom)
        view.backdropContentView.isHidden = backdropPicture == nil || !showsStill
        if showsStill {
            view.stillContentView.alpha = 1
            view.contentView.alpha = 0
        }
        CATransaction.commit()

        // Only the way back out is animated (a hard cut is a source change; this makes it settle). Instant on the way in.
        if showsStill != context.coordinator.showsStill {
            context.coordinator.showsStill = showsStill
            if !showsStill {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.18)
                CATransaction.setAnimationTimingFunction(
                    CAMediaTimingFunction(name: .easeInEaseOut)
                )
                view.stillContentView.alpha = 0
                view.contentView.alpha = 1
                CATransaction.commit()
            }
        }

    }
}
