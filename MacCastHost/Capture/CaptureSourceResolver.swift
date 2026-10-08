import AppKit
import CoreGraphics
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

/// A filter for a capture source and the region of it worth streaming. Only correct as a pair: the rectangle is in the filter's coordinate space, so taking one without the other crops the wrong part silently.
struct CaptureFilterPlan {
    let filter: SCContentFilter

    /// In points in the display's logical space (what `SCStreamConfiguration.sourceRect` documents). `nil` for a whole display or a `desktopIndependentWindow` filter.
    let sourceRect: CGRect?
}

protocol CaptureSourceResolver: Sendable {
    func catalog() async throws -> CaptureCatalog

    /// Requires a prior ``catalog()`` call.
    func makeFilter(for source: CaptureSource) throws -> CaptureFilterPlan

    func inputTransform(for source: CaptureSource) -> InputTransform

    /// Moves to the desktop an application is on when it is not showing, since an application's capture is built from on-screen windows. A window needs no move.
    func bringOnScreen(_ source: CaptureSource) async

    /// Re-photographs the desktop showing on each display, ahead of the age check.
    func refreshSpacePreviews() async

    /// Asked for by ``RemoteCommand/refreshSourceThumbnails``. No schedule or age check: only the client knows a grid is on screen.
    func refreshSourceThumbnails() async

    /// One pass of the watch loop: pushes the catalogue only when a picture changed. Re-enumerating windows costs far more than the screenshots, so only when `reenumerate`.
    func refreshChangedSourceThumbnails(reenumerate: Bool) async

    func refreshChangedSpacePreviews() async

    /// No notification covers a window closing, so a capture noticing is the only way to find out. Also forgets uncapturable marks, since a launch, quit or screen change changes that answer. See ``markUncapturable(_:)``.
    func invalidate()

    func invalidateIfWindowsMoved()

    /// ScreenCaptureKit lists windows it will not render; only a capture that produced no frame separates them. See ``ScreenCaptureSourceResolver/uncapturable``.
    func markUncapturable(_ source: CaptureSource)

    /// A screenshot, not a stream frame: reaching into the capture queue for a thumbnail would put this window's refresh in front of the phone's.
    func snapshot(of source: CaptureSource, maxWidth: Int) async -> CGImage?
}
