import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// Where the chrome goes, in each orientation.
extension RemoteScreen {
    // MARK: - Controls

    /// Whether the strip of Macs is drawn at all.
    ///
    /// **One Mac is nearly everybody, and their screen does not change at all.** A strip with a
    /// single tab on it is a row of chrome that tells somebody with one Mac nothing they did not
    /// already know, and it takes a line off the picture to do it. The `+` that opens a second Mac
    /// lives on that strip, so this costs a one-Mac user the discovery of the feature — which is
    /// what the picker is for, and the picker is a screen they already know how to reach.
    var hasSeveralMacs: Bool { model.openSessions.count > 1 }

    /// How wide the bar may be on a screen that has rails down its sides.
    ///
    /// The space between them, with a gap's worth of daylight either side: the rails are
    /// ``ChromeMetrics/panelWidth`` wide and inset by ``ChromeMetrics/edgeInset``, and
    /// ``ChromeMetrics/panelGap`` is what keeps a panel from touching one. A cap rather than a
    /// fraction of the screen, because what the bar has to clear is a control rather than a margin.
    ///
    /// And never wider than ``ChromeMetrics/statusBarMaxWidth``: on a wide landscape phone or an
    /// iPad the space between the rails is most of the screen, and a long window title would take
    /// all of it.
    ///
    /// Portrait needs none: it has no rails, and the pill's own two lines are what it must fit in.
    func statusBarWidthCap(in available: CGFloat) -> CGFloat {
        let perSide = ChromeMetrics.panelWidth + ChromeMetrics.edgeInset + ChromeMetrics.panelGap
        return min(ChromeMetrics.statusBarMaxWidth, max(0, available - 2 * perSide))
    }

    /// The whole of the chrome put away, and one control to bring it back.
    ///
    /// **What it is for.** The picture is why a session exists, and every control around it is a
    /// band of it that is not the Mac: two rails, a pill, a row of pointer keys. Somebody who is
    /// *reading* their Mac rather than driving it touches none of them, and what they get is the
    /// whole screen. Driving it still works: every touch that is not this disc goes to the Mac
    /// exactly as it did.
    ///
    /// **The way back is the only control left, and it is deliberately in a corner.** A mode whose
    /// exit cannot be found is a trap, so it is the same disc, size and shape and glass, as the
    /// dots beside the pill: one control the user has already pressed, in a different corner.
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

    /// Puts the chrome away, and lets go of every region it was claiming.
    ///
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
                            // Input tools stay together on the left. They open UI rather than
                            // acting on the Mac immediately, so they belong with the other mode
                            // and source controls instead of among one-tap shortcuts.
                            keysButton
                            shortcutsButton
                            clipboardButton
                            modeButton
                            sourcesButton
                            settingsButton
                        }
                        .reportChromeFrame(.leadingRail, into: $chromeFrames)
                        // The left rail is the one a first-run tip rings. The right one holds the
                        // keys that come back to the same panels, and a highlight around both ends
                        // of a landscape screen is a highlight around the picture.
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
                // Under the pill rather than beside it, in both orientations: the pill is about
                // the connection the user is watching and the strip is about the others, and
                // stacking them is what lets the strip disappear without moving the pill.
                //
                // **And in landscape it disappears with the pill**, which is the gesture the pill
                // already teaches: a tap on it opens the session's own readouts, and the strip of
                // the other Macs is part of the same question. Portrait keeps it standing, because
                // the dock below it stands — see the other call site.
                if hasSeveralMacs, statusBarExpanded {
                    SessionTabs(chromeFrames: $chromeFrames)
                }

                // The panel comes *before* the bottom row in this stack, not after it. Both are
                // bottom-anchored by the spacer above, so a panel added below the row pushed the
                // row up the screen — and the row is the pointer and the keys around it, which
                // then landed under the buttons in the rail. Adding it above means the panel
                // grows up over the picture and the controls it belongs to stay where they are.
                // The panel lies *over* the bottom controls rather than stacked above them.
                //
                // Stacked, it had to share the height with the wheel and the pointer column, and
                // what was left over on a landscape phone was not enough for two screens of
                // desktops — so it scrolled inside a box smaller than it needed and sat high up
                // the screen with its bottom edge nowhere near the bottom. Laid over them it can
                // be as tall as its contents and still end at the bottom edge, and the controls
                // it covers are one tap away from coming back, because a tap outside the panel
                // closes it.
                //
                // They share the width rather than fighting for it: the panel is centred and the
                // wheel and pointer column live at the two edges, so on any screen wide enough
                // to hold both, nothing is actually hidden.
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
                            // Return above the pointer and Back beside it, so the thumb resting on
                            // the stick reaches both without crossing the screen.
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

                    // **Below the panel and below the controls, at the very bottom edge.** The
                    // strip is opened over the picture and taken away again, so what it must not do
                    // is move anything: it is the last layer of a stack that is already anchored,
                    // and the wheel and the pointer keep the corners they have always had. See
                    // ``applicationDock``.
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
            // And the dock's, for the same reason in the same place: this region belongs to the
            // portrait dock as well as to the handle, so a rotation into landscape with nothing
            // running would leave a band across the bottom of the picture that no control is left
            // standing in, and so would opening a panel, which takes the handle away with it. See
            // ``chromeFramePresence(_:into:when:)``.
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
                    //
                    // The frame is still the whole screen. Only the content inside it has moved:
                    // the reported rect is measured from the control itself, so everything that
                    // reads it — the touches the canvas must not take — follows it here.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, dockHeight + ChromeMetrics.edgeInset + ChromeMetrics.panelGap)

                    // Landscape's bottom-left corner, brought over so portrait shows that it can
                    // scroll too. Not over a whole arrangement, which takes no input.
                    if !model.isShowingMosaic {
                        ScrollWheelView(
                            onNotch: wheelNotch(_:),
                            label: wheelLabel,
                            position: interactionMode == .observe ? zoomPosition : nil
                        )
                            .reportChromeFrame(.wheel, into: $chromeFrames)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(.leading, ChromeMetrics.edgeInset)
                            .padding(.bottom, dockHeight + ChromeMetrics.edgeInset + ChromeMetrics.panelGap)
                    }
                }

                VStack(spacing: 0) {
                    statusBar(availableWidth: available.width)
                        .tourAnchor(.screenStatus)
                    // Standing permanently here, where landscape's collapses with the pill: this
                    // is the orientation the dock sits at the bottom of, and a bar of Macs that
                    // came and went while the dock stayed would be the one piece of chrome on the
                    // screen with a mind of its own.
                    if hasSeveralMacs {
                        SessionTabs(chromeFrames: $chromeFrames)
                            .padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                    // Above the dock, for the same reason as in landscape: below it there is
                    // nothing left to push it into.
                    floatingPanel(available, isLandscape: false)
                        .padding(.bottom, ChromeMetrics.panelGap)
                    // Standing down while the keyboard is up. Typing is the activity then, and
                    // the dock is a row of pointer controls the keyboard covers or crowds — and
                    // the joystick goes with it, for the same reason in both orientations: the
                    // hands are on the keys.
                    if !model.showKeyboard {
                        portraitDock(width: available.width * ChromeMetrics.dockWidthFraction)
                            .reportChromeFrame(.dock, into: $chromeFrames)
                            .padding(.bottom, ChromeMetrics.edgeInset)
                            // The dock's own step, and the rails' is the landscape one. Only ever
                            // one of the two is on screen, and the tour drops whichever is not:
                            // see ``Tour/screen``.
                            .tourAnchor(.screenDock)
                    }
                }
            }
            // The wheel goes with the keyboard, and a removed view leaves its region behind.
            .chromeFramePresence(.wheel, into: $chromeFrames, when: !model.showKeyboard && !model.isShowingMosaic)
            // The same hazard from the strip's side, and answered the same way: this branch is
            // the one that is here while the strip is not, so this is where its region is let go
            // of when the last Mac but one is closed. See ``chromeFramePresence(_:into:when:)``.
            .chromeFramePresence(.sessionTabs, into: $chromeFrames, when: hasSeveralMacs)
            .animation(Motion.settle, value: interactionMode)
        }
    }

}
