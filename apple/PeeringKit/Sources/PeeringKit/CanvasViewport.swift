import CoreGraphics
import Foundation

/// The zoom and pan rules of the remote picture, with no view in the way.
public enum CanvasViewport {
    /// The picture never shrinks below the screen: there is nothing to see in a smaller one.
    public static let minimumZoom: CGFloat = 1
    public static let maximumZoom: CGFloat = 8

    /// How far past its own edge a zoomed picture may be dragged, as a share of the canvas.
    /// Half takes a corner of the picture to the middle of the screen, which is as far as is useful.
    static let overscrollShare: CGFloat = 0.5
    /// How far above 1x the zoom must be for the full overscroll to apply.
    static let overscrollRamp: CGFloat = 0.5
    /// Travel allowed around the centre when the picture is smaller than the canvas.
    static let underfitTravel: CGFloat = 80
    /// How far under 1x the drawn scale goes before the travel is spent: a picture inset by the chrome sits a little under it.
    static let underfitRange: CGFloat = 0.5

    public static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, minimumZoom), maximumZoom)
    }

    /// Where `zoom` sits on the wheel, 0 at the minimum and 1 at the maximum, on a log scale.
    public static func wheelPosition(zoom: CGFloat) -> CGFloat {
        let low = log(minimumZoom)
        let high = log(maximumZoom)
        guard high > low, zoom > 0 else { return 0 }
        return min(max((log(zoom) - low) / (high - low), 0), 1)
    }

    /// Thickness of the overlaid chrome, measured from the rects it reports, plus `gap`.
    /// Each rect counts from the edge it sits against: the nearer of its two distances.
    public static func chromeMargin(_ chrome: [CGRect], canvas: CGSize, gap: CGFloat) -> CGSize {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        var horizontal: CGFloat = 0
        var vertical: CGFloat = 0
        for rect in chrome {
            horizontal = max(horizontal, min(rect.minX, canvas.width - rect.maxX))
            vertical = max(vertical, min(rect.minY, canvas.height - rect.maxY))
        }
        return CGSize(width: horizontal + gap, height: vertical + gap)
    }

    /// How far the picture's centre may move from the canvas centre on each axis.
    /// `picture` is the drawn size at zoom 1, `effectiveZoom` the scale it is actually drawn at.
    public static func panLimit(
        canvas: CGSize,
        picture: CGSize,
        effectiveZoom: CGFloat,
        margin: CGSize
    ) -> CGSize {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        func limit(_ extent: CGFloat, _ canvas: CGFloat, _ margin: CGFloat) -> CGFloat {
            if effectiveZoom > 1 {
                let slack = (extent * effectiveZoom - canvas) / 2
                let reach = canvas * overscrollShare * min(1, (effectiveZoom - 1) / overscrollRamp)
                let cornerAtCentre = extent * effectiveZoom / 2
                return min(cornerAtCentre, slack > 0 ? slack + max(margin, reach) : reach)
            }
            let underfit = max(0, min(1, (1 - effectiveZoom) / underfitRange))
            return underfitTravel * underfit
        }
        return CGSize(
            width: limit(picture.width, canvas.width, margin.width),
            height: limit(picture.height, canvas.height, margin.height)
        )
    }

    public static func clamped(_ pan: CGSize, to limit: CGSize) -> CGSize {
        CGSize(
            width: min(max(pan.width, -limit.width), limit.width),
            height: min(max(pan.height, -limit.height), limit.height)
        )
    }

    /// A pinch step anchored on the fingers. The pan follows the scale that was actually applied,
    /// so a zoom held at either end of the range does not slide the picture. Not clamped: the
    /// pan range moves with the zoom, and clamping mid-pinch would snap the picture.
    public static func pinched(
        zoom: CGFloat,
        pan: CGSize,
        factor: CGFloat,
        centre: CGPoint,
        canvas: CGSize
    ) -> (zoom: CGFloat, pan: CGSize) {
        let after = clampedZoom(zoom * factor)
        let applied = zoom > 0 ? after / zoom : 1
        return (
            after,
            CGSize(
                width: pan.width * applied + (centre.x - canvas.width / 2) * (1 - applied),
                height: pan.height * applied + (centre.y - canvas.height / 2) * (1 - applied)
            )
        )
    }

    /// The wheel's zoom after `step` (positive zooms out), within the limits.
    public static func wheeled(zoom: CGFloat, step: Double) -> CGFloat {
        clampedZoom(zoom * CGFloat(exp(-step)))
    }
}
