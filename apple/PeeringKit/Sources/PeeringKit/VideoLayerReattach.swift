import Foundation

/// What to do when the display layer a stream draws on is replaced by a new, empty one.
public enum VideoLayerReattach {
    public enum Action: Equatable, Sendable {
        case nothing
        /// Show the last keyframe at once and ask the Mac for a fresh one, because the deltas since are not on the new layer.
        case showKeyframeAndAskForFresh
    }

    /// A Mac with a still screen sends nothing until something moves, so a new layer given no picture stays black. Without a keyframe to show, or with the stream reconfigured and not yet drawing, there is nothing to repaint: the stream's own keyframe is coming.
    public static func action(hasKeyframe: Bool, streamIsLive: Bool) -> Action {
        hasKeyframe && streamIsLive ? .showKeyframeAndAskForFresh : .nothing
    }
}
