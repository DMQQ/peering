import PeeringKit
import SwiftUI

extension SessionSurface {
    /// The rail that lives in the strip down the foldable's right edge, which the system keeps for the camera hole and the clock and which content leaves empty by default. Held upright it is the only rail and carries every button; on its side it carries the right-hand rail's and the left rail stays where it is.
    func reservedStripRail(available: CGSize) -> some View {
        let sideways = DeviceScene.isLandscape
        let strip = sideways ? ChromeMetrics.reservedStripSideways : ChromeMetrics.reservedStripUpright
        let sidePadding = max(ChromeMetrics.edgeInset, strip.centreInset - ChromeMetrics.panelWidth / 2)
        let screenHeight = DeviceScene.window?.screen.bounds.height ?? available.height + DeviceScene.bottomInset
        // The keyboard bar is a bottom inset on `available`, and it reaches the rail only where the screen reserves no strip beside it (the inner display). On the outer display it stops short, so the rail keeps its height; a system keyboard, which spans the screen, always cuts it.
        let barReachesRail = showsKeyboardBar && DeviceScene.trailingInset < ChromeMetrics.panelWidth + 2 * ChromeMetrics.edgeInset
        let floor: CGFloat
        if keyboardOverlap > 0 {
            floor = keyboardOverlap + ChromeMetrics.edgeInset
        } else if barReachesRail {
            floor = screenHeight - available.height + ChromeMetrics.edgeInset
        } else {
            floor = ChromeMetrics.bottomInset
        }
        let height = max(120, screenHeight - strip.clearance - floor)
        return ControlRail(maxHeight: height) {
            stripRailButtons(sideways: sideways, height: height)
        }
        .reportChromeFrame(.trailingRail, into: $chromeFrames)
        .tourAnchor(.screenRail)
        .padding(.top, strip.clearance)
        .padding(.trailing, sidePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .ignoresSafeArea(.container, edges: [.trailing, .bottom])
    }

    /// As many of the extras as the height holds, in the rail's usual order. What is left out is in the Shortcuts panel and the keyboard bar, and the rail still scrolls if even its fixed buttons do not fit.
    @ViewBuilder
    private func stripRailButtons(sideways: Bool, height: CGFloat) -> some View {
        let capacity = ChromeCapacity.rows(
            height: height,
            buttonHeight: ChromeMetrics.buttonHeight,
            gap: ChromeMetrics.buttonGap,
            padding: ChromeMetrics.railPadding
        )
        let fixed = sideways ? 0 : 6
        let shown = ChromeCapacity.optionalCounts(capacity: capacity, fixed: fixed, groups: [quickActions.count, 1, 1, DockControl.navigation.count])
        if !sideways {
            keysButton
            shortcutsButton
            clipboardButton
            modeButton
            sourcesButton
            settingsButton
        }
        ForEach(quickActions.prefix(shown[0])) { action in
            ShortcutRailButton(
                chord: action.chord,
                label: action.label,
                accessibilityLabel: action.accessibilityLabel,
                action: action.action
            )
        }
        if shown[1] > 0 { escapeButton }
        if shown[2] > 0 { tabButton }
        if shown[3] > 0 { navigationButtons }
    }
}
