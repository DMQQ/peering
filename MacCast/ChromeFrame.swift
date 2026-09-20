import MacCastKit
import SwiftUI

/// A piece of chrome that owns the touches that land on it.
///
/// Internal rather than file-private because the panels that report their frames are views of
/// their own, in files of their own. The alternative — one file holding the screen and everything
/// drawn on it — is how this one reached a thousand lines.
enum ChromeRegion: Hashable {
    case leadingRail
    case trailingRail
    /// The scroll wheel, on its own rather than as part of the row it sits in.
    ///
    /// A row is mostly empty space between its controls, and a region that covers the whole row
    /// claims all of it: touches in the gap would stop reaching the Mac, and — worse — a tap
    /// beside an open panel would count as landing on chrome and so would neither dismiss the
    /// panel nor click anything. Reporting the controls is what makes the gaps behave like the
    /// picture they are.
    case wheel
    /// The joystick with Return and Back above and beside it.
    case pointer
    case panel
    case statusBar
    /// The row of Macs, when there is more than one.
    ///
    /// **Reported as the whole row rather than as its controls**, unlike the wheel. The gaps
    /// between two tabs are a few points wide and lead nowhere the user meant to touch, so a
    /// press that slips between two names is a press that misses rather than one that lands on
    /// the Mac behind the strip — and the strip sits directly over the picture's top edge.
    case sessionTabs
    case dock
}

/// Reports where a piece of chrome is, in the canvas's coordinates.
///
/// The gesture surface needs to be told, because it cannot work it out: it is a UIKit view and
/// the chrome is SwiftUI drawing on top of it, so a touch aimed at a button is delivered to the
/// canvas as well. See ``CanvasGeometry/isBlocked``.
struct ChromeFrameReporter: ViewModifier {
    let region: ChromeRegion
    @Binding var frames: [ChromeRegion: CGRect]

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { rect in
            // Guarded, because writing state from a layout callback that state feeds back into
            // is how a layout loop starts.
            if frames[region] != rect {
                frames[region] = rect
            }
        }
    }
}

extension View {
    func reportChromeFrame(
        _ region: ChromeRegion,
        into frames: Binding<[ChromeRegion: CGRect]>
    ) -> some View {
        modifier(ChromeFrameReporter(region: region, frames: frames))
    }

    /// Says whether a piece of chrome is on screen at all, so its region can be let go of.
    ///
    /// **A reported region outlives the view that reported it.** ``ChromeFrameReporter`` only ever
    /// writes: a view that is removed leaves its last rectangle behind, and the gesture surface
    /// goes on blocking touches inside it. Chrome that can vanish therefore leaves a dead band
    /// lying over the picture, which neither dismisses a panel nor clicks the Mac — the user
    /// presses a button and nothing at all happens.
    ///
    /// **Applied to a view that is always there, which is why this is a second step rather than a
    /// parameter of the reporter.** A modifier written inside the `if` is removed with the view it
    /// is on, and the moment this is needed is the moment it is gone. So it goes on the container
    /// that holds the chrome, and answers `nil` for it when the chrome is not being drawn.
    ///
    /// Cleared to `nil` rather than to an empty rectangle. The gestures ask *whether a point is
    /// inside a region*, and the two answers that make that question false are "here is a region
    /// that does not cover you" and "there is no region". Absent is the one that is true, and it
    /// is the one that removes the entry rather than leaving a row claiming to describe something.
    func chromeFramePresence(
        _ region: ChromeRegion,
        into frames: Binding<[ChromeRegion: CGRect]>,
        when isPresent: Bool
    ) -> some View {
        modifier(ChromeFramePresence(region: region, frames: frames, isPresent: isPresent))
    }
}

/// The other half of ``ChromeFrameReporter``: takes a region back when its chrome goes away.
struct ChromeFramePresence: ViewModifier {
    let region: ChromeRegion
    @Binding var frames: [ChromeRegion: CGRect]
    let isPresent: Bool

    func body(content: Content) -> some View {
        content
            // `initial: true`, so a strip that was never drawn does not leave a region behind from
            // the last time it was. Guarded on `nil` for the reason the reporter is guarded: this
            // writes state that a layout pass reads, and an unguarded write from here is how a
            // layout loop starts.
            .onChange(of: isPresent, initial: true) { _, present in
                if !present, frames[region] != nil {
                    frames[region] = nil
                }
            }
    }
}
