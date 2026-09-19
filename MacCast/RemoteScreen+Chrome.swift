import RemoteCore
import SwiftUI
import UIKit

/// Where the chrome goes, in each orientation.
///
/// An extension rather than a file of its own type: state and its gestures have to
/// agree about what the picture is, and the view is easier to read in pieces than as
/// one file of two thousand lines. Members are `internal` here because Swift's
/// `private` is file-scoped — see the note in `RemoteScreen`.
extension RemoteScreen {
    // MARK: - Controls

    @ViewBuilder
    func sessionChrome(isLandscape: Bool, available: CGSize) -> some View {
        if isLandscape {
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
                            modeButton
                            sourcesButton
                            desktopsButton
                            settingsButton
                        }
                        .reportChromeFrame(.leadingRail, into: $chromeFrames)
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

                // The pill's own width plus the dots, so the cap goes on doing what it was for —
                // keeping the pill from crossing a landscape screen — to the pill. Left at 420
                // it would have started constraining the status rows instead, since the dots
                // moved inside it.
                statusBar.frame(maxWidth: Self.pillMaxWidth + Self.sessionDotsWidth)

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
                                .offset(x: joystickColumnOffset)
                        }
                    }
                    .padding(.horizontal, ChromeMetrics.edgeInset)
                    .padding(.bottom, ChromeMetrics.bottomInset)

                    floatingPanel(available, isLandscape: true)
                        .padding(.bottom, ChromeMetrics.bottomInset)
                }
                // Anchored to the bottom by the frame, not by the spacer above. A spacer only
                // holds a column down while there is room to spare: the moment a panel made the
                // contents taller than the screen the spacer collapsed to nothing, and this
                // whole stack — which the enclosing ZStack aligns to the *top* — slid up the
                // screen with it. The panel ended up at the top and the pointer off the bottom.
                // An alignment pins the bottom edge whatever the content does.
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
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
                }

                VStack(spacing: 0) {
                    statusBar
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
                    }
                }
            }
            .onAppear {
                // The wheel is landscape's, and its frame is in the canvas's coordinates rather
                // than the portait layout's — so rotating back leaves a rectangle of the screen
                // blocked for touches, over a control that is no longer there to receive them.
                chromeFrames[.wheel] = nil
            }
            .animation(Motion.settle, value: interactionMode)
        }
    }

}
