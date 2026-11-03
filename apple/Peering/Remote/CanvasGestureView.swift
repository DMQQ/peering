import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

struct CanvasGestureView: UIViewRepresentable {
    var onTouchDown: (CGPoint) -> Void
    var onTouchMove: (CGPoint) -> Void
    var onTouchUp: (CGPoint) -> Void
    var onSecondaryClick: (CGPoint) -> Void
    var onHover: (CGPoint) -> Void = { _ in }
    var onScroll: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    var onPanCanvas: (CGSize) -> Void
    var onSizeChange: (CGSize) -> Void
    var interactionMode: InteractionMode
    var isZoomed: Bool = false
    var blockedRegions: [CGRect] = []
    var isMosaicShowing: Bool = false
    var onMosaicTap: (CGPoint) -> Void = { _ in }
    var onMosaicLift: (CGPoint) -> Void = { _ in }
    var onMosaicDrag: (CGPoint) -> Void = { _ in }
    var onMosaicDrop: () -> Void = {}
    var onPictureTap: () -> Bool = { false }
    var onMultiFingerSwipe: (TrackpadSwipe) -> Void = { _ in }
    func makeUIView(context: Context) -> GestureSurfaceView {
        let view = GestureSurfaceView()
        view.interactionMode = interactionMode
        view.isZoomed = isZoomed
        view.blockedRegions = blockedRegions
        view.isMosaicShowing = isMosaicShowing
        view.handlers = .init(
            onTouchDown: onTouchDown,
            onTouchMove: onTouchMove,
            onTouchUp: onTouchUp,
            onSecondaryClick: onSecondaryClick,
            onHover: onHover,
            onScroll: onScroll,
            onZoom: onZoom,
            onPanCanvas: onPanCanvas,
            onSizeChange: onSizeChange,
            onMosaicTap: onMosaicTap,
            onMosaicLift: onMosaicLift,
            onMosaicDrag: onMosaicDrag,
            onMosaicDrop: onMosaicDrop,
            onPictureTap: onPictureTap,
            onMultiFingerSwipe: onMultiFingerSwipe
        )
        return view
    }

    func updateUIView(_ view: GestureSurfaceView, context: Context) {
        // The closures capture the current view state (zoom, pan, canvas size), so they are
        // replaced on every update rather than captured once in `makeUIView`.
        view.interactionMode = interactionMode
        view.isZoomed = isZoomed
        view.blockedRegions = blockedRegions
        view.isMosaicShowing = isMosaicShowing
        view.handlers = .init(
            onTouchDown: onTouchDown,
            onTouchMove: onTouchMove,
            onTouchUp: onTouchUp,
            onSecondaryClick: onSecondaryClick,
            onHover: onHover,
            onScroll: onScroll,
            onZoom: onZoom,
            onPanCanvas: onPanCanvas,
            onSizeChange: onSizeChange,
            onMosaicTap: onMosaicTap,
            onMosaicLift: onMosaicLift,
            onMosaicDrag: onMosaicDrag,
            onMosaicDrop: onMosaicDrop,
            onPictureTap: onPictureTap,
            onMultiFingerSwipe: onMultiFingerSwipe
        )
    }
}
