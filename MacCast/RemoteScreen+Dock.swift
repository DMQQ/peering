import RemoteCore
import SwiftUI
import UIKit

/// The portrait dock and the shortcuts panel.
///
/// An extension rather than a file of its own type: state and its gestures have to
/// agree about what the picture is, and the view is easier to read in pieces than as
/// one file of two thousand lines. Members are `internal` here because Swift's
/// `private` is file-scoped — see the note in `RemoteScreen`.
extension RemoteScreen {
    var shortcutsPanel: some View {
        VStack(spacing: 8) {
            if model.showKeyboard, !model.typedPreview.isEmpty {
                HStack {
                    Text(model.typedPreview)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        // Head-truncate so the most-recently-typed characters stay visible
                        // when the preview is wider than the available space.
                        .truncationMode(.head)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let profile = activeApplicationProfile {
                applicationActions(profile)
            }

            MacroBar()

            HStack(spacing: 10) {
                ModifierBar()
                Spacer()
                Button(model.keyboardMode.label) {
                    model.setKeyboardMode(model.keyboardMode == .unicode ? .keycode : .unicode)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }

            arrowStrip
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 10)
        .reportChromeFrame(.panel, into: $chromeFrames)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// What the Mac is showing, if we know anything about it.
    ///
    /// The bundle identifier arrives with the catalogue — every picker row already carries one —
    /// so this needs nothing from the host beyond what is already on the wire. See
    /// ``ApplicationActions`` for the table and for why an unknown application resolves to nil
    /// rather than to a guess.
    var activeApplicationProfile: ApplicationProfile? {
        guard let activeSourceID = model.activeSourceID else { return nil }
        let bundleID = model.catalog?.all.first { $0.id == activeSourceID }?.bundleIdentifier
        return ApplicationActions.profile(forBundleID: bundleID)
    }

    /// The keystrokes that only make sense for what is running, above the ones that make sense
    /// for everything.
    ///
    /// The macro bar below is the same seventeen keys whatever is on screen, which is the right
    /// answer for a list that has to work everywhere and the wrong one for a terminal: the keys
    /// a shell wants are not the keys a browser wants, and the person driving a shell from a
    /// phone knows exactly which ones they want and cannot reach them.
    ///
    /// Absent entirely for an application nobody has written a profile for, rather than shown
    /// empty. A heading with nothing under it is worse than no heading.
    func applicationActions(_ profile: ApplicationProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(profile.name)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(profile.actions) { action in
                        Button {
                            sendKey(keyCode: action.keyCode, modifiers: action.modifiers)
                        } label: {
                            Text(action.title)
                                .font(.system(size: 14, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .glassEffect(
                                    .regular.interactive(),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                        }
                        .buttonStyle(RailButtonStyle(scale: 0.86))
                        // The keystroke is the visible label and the reason is not, so the
                        // reason is what gets spoken.
                        .accessibilityLabel(action.detail)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    /// The arrow keys, plus the two keys a software keyboard cannot send as navigation.
    ///
    /// A single row rather than the inverted T of a physical cluster: this shares a panel with
    /// the macros and the modifiers, and three rows of keys would make it taller than the thing
    /// it is helping with.
    var arrowStrip: some View {
        HStack(spacing: 4) {
            compactKeyButton(icon: "chevron.left", keyCode: 123)
            compactKeyButton(icon: "chevron.up", keyCode: 126)
            compactKeyButton(icon: "chevron.down", keyCode: 125)
            compactKeyButton(icon: "chevron.right", keyCode: 124)
            compactKeyButton(icon: "return", keyCode: 36) { model.pressReturn() }
            compactKeyButton(icon: "delete.backward", keyCode: 51)
        }
    }

    /// How tall the dock stands at the moment.
    ///
    /// The one piece of portrait chrome whose height changes, and the pointer above it is placed
    /// from it rather than from a second number that would have to be kept in step. Read from the
    /// same two constants the dock is built from, so opening it lifts the pointer by exactly the
    /// row that appeared.
    var dockHeight: CGFloat {
        dockExpanded ? ChromeMetrics.dockExpandedHeight : ChromeMetrics.dockCollapsedHeight
    }

    /// The same controls as the landscape rails, in a bar that opens like the status pill does.
    ///
    /// Eight buttons across a phone held upright is a bar with no room left for the picture, and
    /// four of those eight are reached for continuously while the other four are not. So the
    /// shut rail is the four that are, and the chevron at the end of the row opens it onto the
    /// rest — the same gesture, the same spring and the same morphing corner as the pill above
    /// it, because they are the same kind of object: a bar of glass that grows when asked.
    ///
    /// The two rows share a column grid, the chevron's column included. Row two's four buttons
    /// are inset by exactly the chevron's width so that they line up under row one's — a second
    /// row whose buttons sat half a button to the left of the ones above it is the sort of thing
    /// nobody can name and everybody can see.
    func portraitDock(width: CGFloat) -> some View {
        ZStack(alignment: .top) {
            if dockExpanded {
                VStack(spacing: ChromeMetrics.buttonGap) {
                    HStack(spacing: 0) {
                        modeButton
                        sourcesButton
                        keysButton
                        shortcutsButton
                        dockToggle
                    }
                    HStack(spacing: 0) {
                        desktopsSlot
                        escapeButton
                        tabButton
                        settingsButton
                        // The chevron's column, which this row alone leaves free. A move
                        // control is the one thing here that had nowhere else to go: row one
                        // is full, row three is the five navigation keys, and the alternative
                        // was giving up a control people use to make room for one they reach
                        // for now and then.
                        moveButton
                    }
                    // The keys the landscape rail keeps below its fold, which portrait had no
                    // equivalent for at all. Five of them and five columns, so each lands in a
                    // column of its own and the row needs no empty cell to stay in step — which
                    // is the whole reason five is the number (see ``ChromeMetrics/dockColumns``).
                    HStack(spacing: 0) {
                        navigationButtons
                    }
                }
            } else {
                HStack(spacing: 0) {
                    modeButton
                    sourcesButton
                    keysButton
                    shortcutsButton
                    dockToggle
                }
            }
        }
        .padding(.vertical, ChromeMetrics.railPadding)
        .padding(.horizontal, ChromeMetrics.railSidePadding)
        .frame(width: width)
        .clipShape(dockShape)
        .glassEffect(.regular, in: dockShape)
    }

    /// The dock's outline, in whichever state it is in — see ``pillShape``, which this is a
    /// second reading of. The buttons divide whatever width they are given, so the two states
    /// differ in height alone; the corner is what tells the eye the bar has opened rather than
    /// been swapped for a taller one.
    var dockShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: dockExpanded
                ? ChromeMetrics.dockExpandedRadius
                : ChromeMetrics.dockCollapsedRadius,
            style: .continuous
        )
    }

    /// The dock's own chevron: the one thing in the row that is not a control for the Mac.
    ///
    /// The buttons fill their rows between them, so there is no gap left to tap — an expanding
    /// bar of solid controls has nowhere to put the gesture unless it is given a cell of its
    /// own. It is wordless because it says nothing about the Mac; it only says there is more
    /// bar.
    ///
    /// A whole column, not the narrow slot it began as. The grid it sits in is five even cells,
    /// and a chevron on a column of its own is what lets the row below it be five keys rather
    /// than four keys and a gap. The extra width costs nothing the row was using: it is the
    /// tap target for the one control here that has no caption to aim at.
    var dockToggle: some View {
        Button {
            withAnimation(Motion.morph) { dockExpanded.toggle() }
        } label: {
            Image(systemName: dockExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: ChromeMetrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
        .accessibilityLabel(dockExpanded ? "Hide the other controls" : "Show the other controls")
    }

    /// The pointer in portrait: the stick above the dock, with the two keys either side of it.
    ///
    /// Return moves off the stick's axis to its right, and Back keeps the left, so the row is
    /// only ever one control tall — a key stacked above the stick would be a key over the middle
    /// of the picture, which is the part of the Mac the user is trying to see.
    ///
    /// Both keys are given the same frame whatever size they are drawn at, so the row balances
    /// around the stick and the stick lands on the centre exactly. Framed to their own widths,
    /// the smaller Back would leave the stick seven points off the middle — which is the amount
    /// that reads as the screen being slightly crooked rather than as a mistake.
    var portraitPointer: some View {
        HStack(alignment: .center, spacing: ChromeMetrics.panelGap) {
            backKey
                .frame(width: ChromeMetrics.quickKeySize, height: ChromeMetrics.quickKeySize)
            joystick()
            returnKey
                .frame(width: ChromeMetrics.quickKeySize, height: ChromeMetrics.quickKeySize)
        }
    }

    /// Pixels straight through: the wheel has its own travel-to-pixels scale, unlike the
    /// two-finger gesture which is doubled here because a point of finger travel moving one
    /// pixel would make scrolling a page take several swipes.
}
