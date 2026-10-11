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

/// A plain container, so the picture can be moved without moving the layer PiP mirrors.
final class VideoHostView: UIView {
    /// Carries the zoom and pan, never touched by SwiftUI. A subview of its own because SwiftUI sets the representable's frame and UIKit answers by shrinking `bounds` until `bounds × transform` equals it, undoing every pinch on the next layout.
    /// A translation is not compensated, so panning looked fine while zoom was broken.
    let contentView = UIView()

    /// The window's rectangle. Not this view's own bounds: the keyboard closing animates this height and the picture swayed re-fitting into each step.
    let clipView: UIView = {
        let view = UIView()
        view.clipsToBounds = true
        return view
    }()

    let displayView = VideoDisplayView()

    /// The outgoing picture, still, under the live one. A source change cannot be made atomic (the layer swaps contents on the render server's clock, the transform is written by the main thread), so the outgoing picture is held at its own scale and cross-faded, and the mismatched pair is never drawn.
    /// An image, not a second decoder: a decoder needs reference frames, so it showed a run's first frame until it caught up. See ``VideoRenderer/displayedPicture()``.
    let stillContentView = UIView()
    let stillView: UIView = {
        let view = UIView()
        // Same fit as the display layer, so rects computed from a pixel size land on the picture exactly.
        view.layer.contentsGravity = .resizeAspect
        // Clear, not black: black bars would cover neighbouring tiles when shrunk into one.
        return view
    }()
    let backdropContentView = UIView()
    let backdropView: UIView = {
        let view = UIView()
        view.layer.contentsGravity = .resizeAspect
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // The scaled content view paints outside the bounds unless clipped, and sublayers are not clipped by default. The clip is ``clipView``.
        addSubview(clipView)

        // Under the live one and sized the same: it is what stays on screen when the live layer fades out.
        for (container, display) in [(backdropContentView, backdropView), (stillContentView, stillView), (contentView, displayView)] {
            container.frame = bounds
            clipView.addSubview(container)
            display.frame = container.bounds
            display.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(display)
        }
        stillContentView.alpha = 0
        backdropContentView.isHidden = true
    }

    /// Sized through `bounds` and `center`, never `frame`: UIKit answers a frame set on a transformed view by shrinking bounds, which undid every zoom.
    override func layoutSubviews() {
        super.layoutSubviews()
        clipView.frame = window.map { convert($0.bounds, from: $0) } ?? bounds
        let size = clipView.bounds.size
        for container in [backdropContentView, stillContentView, contentView] {
            container.bounds = CGRect(origin: .zero, size: size)
            container.center = CGPoint(x: size.width / 2, y: size.height / 2)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
