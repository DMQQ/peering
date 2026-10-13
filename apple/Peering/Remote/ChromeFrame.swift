import PeeringKit
import SwiftUI

enum ChromeRegion: Hashable {
    case leadingRail
    case trailingRail
    /// Reports the wheel's controls, not the whole row: a region over the row's gaps would stop touches reaching the Mac.
    case wheel
    case pointer
    case panel
    case statusBar
    /// Reported as the whole row, unlike the wheel: a press slipping between two tabs should miss, not land on the Mac behind.
    case sessionTabs
    case dock
    case immersiveEscape
}

/// The gesture surface is UIKit under SwiftUI chrome, so a touch aimed at a button also reaches the canvas. See ``CanvasGeometry/isBlocked``.
struct ChromeFrameReporter: ViewModifier {
    let region: ChromeRegion
    @Binding var frames: [ChromeRegion: CGRect]

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { rect in
            // Guarded: writing state that a layout callback feeds back into starts a layout loop.
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

    /// A reported region outlives its view, because the reporter only writes. Chrome that can vanish leaves a dead band blocking touches, so this goes on an always-present container and clears to nil (no region), not to an empty rect.
    func chromeFramePresence(
        _ region: ChromeRegion,
        into frames: Binding<[ChromeRegion: CGRect]>,
        when isPresent: Bool
    ) -> some View {
        modifier(ChromeFramePresence(region: region, frames: frames, isPresent: isPresent))
    }
}

struct ChromeFramePresence: ViewModifier {
    let region: ChromeRegion
    @Binding var frames: [ChromeRegion: CGRect]
    let isPresent: Bool

    func body(content: Content) -> some View {
        content
            // Guarded on nil for the same layout-loop reason as the reporter.
            .onChange(of: isPresent, initial: true) { _, present in
                if !present, frames[region] != nil {
                    frames[region] = nil
                }
            }
    }
}
