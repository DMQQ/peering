import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    // MARK: - Controls

    var hasSeveralMacs: Bool { model.openSessions.count > 1 }

    func statusBarWidthCap(in available: CGFloat) -> CGFloat {
        let perSide = ChromeMetrics.panelWidth + ChromeMetrics.edgeInset + ChromeMetrics.panelGap
        return min(ChromeMetrics.statusBarMaxWidth, max(0, available - 2 * perSide))
    }

    var immersiveEscape: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    leaveImmersive()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(ColorPalette.ink)
                        .frame(width: 48, height: 48)
                        .glassSurface(in: Circle())
                }
                .contentShape(Rectangle())
                .buttonStyle(RailButtonStyle(scale: 0.92))
                .reportChromeFrame(.immersiveEscape, into: $chromeFrames)
                .accessibilityLabel("Show the controls")
            }
            Spacer(minLength: 0)
        }
        .padding(ChromeMetrics.edgeInset)
    }

    /// **The regions are given up by hand, and this is the only moment that can.** A reported region
    /// outlives the view that reported it, so the rectangles left behind by rails that are no longer
    /// drawn are bands across the picture where nothing happens at all: the canvas refuses those
    /// touches, and the controls that would have taken them are gone. See
    /// ``chromeFramePresence(_:into:when:)``.
    func enterImmersive() {
        openPanel = nil
        chromeFrames = [:]
        withAnimation(Motion.settle) { isImmersive = true }
    }

    func leaveImmersive() {
        withAnimation(Motion.settle) { isImmersive = false }
    }

    @ViewBuilder
    func sessionChrome(isLandscape: Bool, available: CGSize) -> some View {
        if isImmersive {
            immersiveEscape
        } else if isLandscape {
            ZStack(alignment: .top) {
                // Pinned to the top rather than centred. The rails grew a button each, and a
                // centred rail reaches far enough down that the pointer pad — which lives in
                // the bottom corner the thumb rests on — would land on top of the bottom
                // button and swallow its taps.
                //
                // Inside the safe area, deliberately. iOS reports *symmetric* landscape insets
                // whether or not the sensor housing is actually on that side, so the two edges
                // cannot be treated differently without guessing; content that ignores them runs
                // under the housing, which is a button the user can see and cannot press.
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: ChromeMetrics.panelGap) {
                        ControlRail(maxHeight: railMaxHeight(in: available.height)) {
                            keysButton
                            shortcutsButton
                            clipboardButton
                            modeButton
                            sourcesButton
                            settingsButton
                        }
                        .reportChromeFrame(.leadingRail, into: $chromeFrames)
                        .tourAnchor(.screenRail)
                        Spacer(minLength: 0)
                        ControlRail(maxHeight: railMaxHeight(in: available.height)) {
                            landscapeQuickActions
                            escapeButton
                            tabButton
                            navigationButtons
                        }
                        .reportChromeFrame(.trailingRail, into: $chromeFrames)
                    }
                    .padding(.horizontal, ChromeMetrics.edgeInset)
                    .padding(.top, ChromeMetrics.edgeInset)

                    Spacer(minLength: 0)
                }

                // **Capped at the space between the rails**, and it needs the cap: the pill hugs its
                // contents, and one of those contents is the source's own name — a window's title,
                // which on this Mac is a terminal's 74-character status line. Left alone the bar grew
                // until it was drawn over both rails and the buttons under them. See
                // ``RemoteScreen/statusBarWidthCap(in:)``.
                statusBar(availableWidth: available.width)
                    .frame(maxWidth: statusBarWidthCap(in: available.width))
                    .tourAnchor(.screenStatus)
                if hasSeveralMacs, statusBarExpanded {
                    SessionTabs(chromeFrames: $chromeFrames)
                }

                // The panel comes *before* the bottom row in this stack, not after it. Both are
                // bottom-anchored by the spacer above, so a panel added below the row pushed the
                // row up the screen — and the row is the pointer and the keys around it, which
                // then landed under the buttons in the rail. Adding it above means the panel
                // grows up over the picture and the controls it belongs to stay where they are.
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: ChromeMetrics.panelGap) {
                        ScrollWheelView(
                            onNotch: wheelNotch(_:),
                            label: wheelLabel,
                            position: interactionMode == .observe ? zoomPosition : nil
                        )
                            .reportChromeFrame(.wheel, into: $chromeFrames)
                        Spacer(minLength: 0)
                        if !model.showKeyboard {
                            pointerColumn
                                .reportChromeFrame(.pointer, into: $chromeFrames)
                                .tourAnchor(.screenPointer)
                                .offset(x: joystickColumnOffset)
                        }
                    }
                    .padding(.horizontal, ChromeMetrics.edgeInset)
                    .padding(.bottom, ChromeMetrics.bottomInset)

                    floatingPanel(available, isLandscape: true)
                        .padding(.bottom, ChromeMetrics.bottomInset)

                    applicationDock
                }
                // Anchored to the bottom by the frame, not by the spacer above. A spacer only
                // holds a column down while there is room to spare: the moment a panel made the
                // contents taller than the screen the spacer collapsed to nothing, and this
                // whole stack — which the enclosing ZStack aligns to the *top* — slid up the
                // screen with it. The panel ended up at the top and the pointer off the bottom.
                // An alignment pins the bottom edge whatever the content does.
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            // On the stack itself rather than on the strip, because the strip is not always
            // there and this is the thing that has to notice. A strip that has gone without its
            // region being taken back leaves a band across the top of the picture that swallows
            // every touch aimed at the Mac. See ``chromeFramePresence(_:into:when:)``.
            .chromeFramePresence(
                .sessionTabs,
                into: $chromeFrames,
                when: hasSeveralMacs && statusBarExpanded
            )
            .chromeFramePresence(
                .dock,
                into: $chromeFrames,
                when: applicationDockIsOffered
            )
        } else {
            // Two layers, and the order between them is the whole of the arrangement. The pointer
            // is on the screen's own centre, which is the middle of the picture — so it is drawn
            // *under* the panel rather than over it. An overlay, which is what put it above
            // everything before, would have had a hundred-point disc swallowing the middle of any
            // panel the user opened, with its own controls unreachable underneath.
            ZStack(alignment: .bottom) {
                if !model.showKeyboard {
                    portraitPointer
                        .reportChromeFrame(.pointer, into: $chromeFrames)
                        .tourAnchor(.screenPointer)
                    // Centred across and sitting on the dock, rather than on the screen's own
                    // centre. `maxHeight: .infinity` with no alignment centres its content, so
                    // this filled the screen and put the joystick in the middle of both axes —
                    // the one place on a phone that no thumb can reach comfortably, and half a
                    // screen away from the bar it belongs to.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, dockHeight + ChromeMetrics.edgeInset + ChromeMetrics.panelGap)

                    // A ZStack rather than a Group: Group has no container of its own to animate.
                    ZStack(alignment: .bottomLeading) {
                        if !model.isShowingMosaic {
                            ScrollWheelView(
                                onNotch: wheelNotch(_:),
                                label: wheelLabel,
                                position: interactionMode == .observe ? zoomPosition : nil
                            )
                                .reportChromeFrame(.wheel, into: $chromeFrames)
                                .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(Motion.settle, value: model.isShowingMosaic)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, ChromeMetrics.edgeInset)
                    .padding(.bottom, dockHeight + ChromeMetrics.edgeInset + ChromeMetrics.panelGap)
                }

                VStack(spacing: 0) {
                    statusBar(availableWidth: available.width)
                        .tourAnchor(.screenStatus)
                    if hasSeveralMacs {
                        SessionTabs(chromeFrames: $chromeFrames)
                            .padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                    floatingPanel(available, isLandscape: false)
                        .padding(.bottom, ChromeMetrics.panelGap)
                    if !model.showKeyboard {
                        portraitDock(width: available.width * ChromeMetrics.dockWidthFraction)
                            .reportChromeFrame(.dock, into: $chromeFrames)
                            .padding(.bottom, ChromeMetrics.edgeInset)
                            .tourAnchor(.screenDock)
                    }
                }
            }
            // The wheel goes with the keyboard, and a removed view leaves its region behind.
            .chromeFramePresence(.wheel, into: $chromeFrames, when: !model.showKeyboard && !model.isShowingMosaic)
            .chromeFramePresence(.sessionTabs, into: $chromeFrames, when: hasSeveralMacs)
            .animation(Motion.settle, value: interactionMode)
        }
    }

}
