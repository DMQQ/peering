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
            if frames[region] != rect { frames[region] = rect }
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
}
