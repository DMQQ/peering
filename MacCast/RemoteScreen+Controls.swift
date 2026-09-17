import RemoteCore
import SwiftUI
import UIKit

/// The controls themselves.
///
/// An extension rather than a file of its own type: state and its gestures have to
/// agree about what the picture is, and the view is easier to read in pieces than as
/// one file of two thousand lines. Members are `internal` here because Swift's
/// `private` is file-scoped — see the note in `RemoteScreen`.
extension RemoteScreen {
    // MARK: - The six controls
    //
    // Written once and arranged twice: the landscape rails and the portrait bar are the same
    // six views in a different container. Two hand-maintained copies of this list is how the
    // two orientations drifted apart in the first place — the joystick was permanent in one and
    // opt-in in the other, and nothing said which was right.

    /// The switch the screen is organised around.
    ///
    /// Named for the mode it is *in*, not the one it would switch to: a control that advertises
    /// its destination while sitting in a state you cannot read is how a toggle comes to mean
    /// the opposite of what the user thought they pressed.
    var modeButton: some View {
        RailButton(
            icon: interactionMode.symbol,
            label: interactionMode.label,
            // Filled only in observe. That mode changes the safety contract by blocking input.
            //
            // Filling both was tried, on the grounds that a caption naming the current mode is
            // reporting a state and a state deserves a mark. On the device it read the other
            // way: a button that is never not lit stops being a mark, and it put the loudest
            // thing in the row at the head of it, permanently, in the mode most sessions spend
            // their whole time in.
            selected: interactionMode != .control
        ) {
            withAnimation(Motion.settle) { interactionMode = interactionMode.toggled }
        }
    }

    var sourcesButton: some View {
        // "Apps", which is what the panel holds: the running applications, the installed ones, the
        // windows and the displays, all of them things this Mac can *show*. It said "Share", which
        // is what a screensharing app calls the screen it hands over — and read as the system share
        // sheet, which is a completely different button in everybody's head.
        RailButton(
            icon: "rectangle.on.rectangle",
            label: "Apps",
            selected: openPanel == .sources
        ) {
            withAnimation(Motion.settle) { openPanel = openPanel == .sources ? nil : .sources }
        }
    }

    /// Absent when the Mac has one desktop: a control that can only ever do nothing is clutter,
    /// and this is the one button that can drop out without leaving a hole in the meaning of the
    /// ones around it.
    @ViewBuilder
    var desktopsButton: some View {
        if let info = model.catalog?.spaceInfo, DesktopsPanel.showsDesktops(info) {
            RailButton(
                icon: "rectangle.split.3x1",
                label: "Desktops",
                selected: openPanel == .desktops
            ) {
                withAnimation(Motion.settle) {
                    openPanel = openPanel == .desktops ? nil : .desktops
                }
            }
        }
    }

    /// Desktops, or the room it would have taken.
    ///
    /// The dock's open rows divide their width equally, which is what keeps the second row's
    /// buttons under the first row's. Desktops drops out when the Mac has one desktop and one
    /// screen, and a row of three where the row above has four would then have divided the width
    /// three ways and put its buttons half a button left of the ones they sit under. An empty
    /// cell is the same size as a full one, which is the whole of the fix.
    ///
    /// Here and not in the landscape rail, which is a column: a hole in that one would be a gap
    /// between two buttons rather than a column that stays in step.
    var desktopsSlot: some View {
        ZStack { desktopsButton }
            .frame(maxWidth: .infinity)
            .frame(height: ChromeMetrics.buttonHeight)
    }

    /// A column of the dock with nothing in it.
    ///
    /// The same reasoning as ``desktopsSlot``, reached from the other side: an empty cell is the
    /// same size as a full one, and a row that dropped a column would divide its width between
    /// what was left and put every button in it under the gap between the two above.
    ///
    /// Its height is pinned for the reason the rest of the cell is drawn: a cell is one button
    /// tall, and a cell that can be *any* height is one the layout will happily make tall. A view
    /// constrained in width alone is still flexible in height, and `Color.clear` is the most
    /// flexible thing there is — so the second row of the open dock stretched to take whatever
    /// the column had going spare, and the bar grew over the picture. The buttons beside it could
    /// not do that: they carry a height of their own, which is what a cell's is supposed to be.
    var emptyDockSlot: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: ChromeMetrics.buttonHeight)
            .allowsHitTesting(false)
    }

    /// Whether the desktops panel is worth offering at all.
    ///
    /// More than one desktop, **or** more than one screen. A second screen qualifies on its own
    /// even with a single desktop on it, because tapping that desktop is how the picture is moved
    /// to it — a control that can only ever do nothing is clutter, and this one can do something.
    var keysButton: some View {
        RailButton(
            icon: model.showKeyboard ? "keyboard.fill" : "keyboard",
            // "Keyboard", not the "Keys" this began as. The caption is the only thing on screen
            // that says what an icon does, and "Keys" reads as a row of individual keys — the
            // arrows, the escape, the delete — which are all elsewhere on this very bar. What
            // this opens is the software keyboard.
            label: "Keyboard",
            selected: model.showKeyboard
        ) { model.showKeyboard.toggle() }
    }

    var shortcutsButton: some View {
        RailButton(icon: "command", label: "Shortcuts", selected: openPanel == .shortcuts) {
            withAnimation(Motion.settle) {
                openPanel = openPanel == .shortcuts ? nil : .shortcuts
            }
        }
    }

    /// Escape and tab, on the rail rather than in the shortcuts panel.
    ///
    /// These are the two keys a remote desktop reaches for constantly and a software keyboard
    /// cannot send — dismissing a dialogue, moving between fields — and both were behind a
    /// toggle. The panel keeps its copies for the same reason the arrow strip keeps its return.
    var escapeButton: some View {
        RailButton(icon: "escape", label: "Esc") { sendKey(keyCode: 53) }
    }

    var tabButton: some View {
        RailButton(icon: "arrow.right.to.line", label: "Tab") { sendKey(keyCode: 48) }
    }

    /// The actions reached for while looking at the Mac rather than at Peering itself.
    ///
    /// Ordered by frequency because the rail is intentionally scrollable on shorter phones:
    /// copy, paste and terminal interrupt remain visible first. Destructive quit is present as
    /// requested, but below the everyday edits and behind a confirmation so an edge tap cannot
    /// close an app with unsaved work.
    @ViewBuilder
    var landscapeQuickActions: some View {
        ShortcutRailButton(chord: "⌘C", label: "Copy", accessibilityLabel: "Copy") {
            sendKey(keyCode: 8, modifiers: [.command])
        }
        ShortcutRailButton(chord: "⌘V", label: "Paste", accessibilityLabel: "Paste") {
            sendKey(keyCode: 9, modifiers: [.command])
        }
        ShortcutRailButton(chord: "⌃C", label: "Stop", accessibilityLabel: "Control C") {
            sendKey(keyCode: 8, modifiers: [.control])
        }
        ShortcutRailButton(chord: "⌘Z", label: "Undo", accessibilityLabel: "Undo") {
            sendKey(keyCode: 6, modifiers: [.command])
        }
        ShortcutRailButton(chord: "⌘X", label: "Cut", accessibilityLabel: "Cut") {
            sendKey(keyCode: 7, modifiers: [.command])
        }
        ShortcutRailButton(chord: "⌘S", label: "Save", accessibilityLabel: "Save") {
            sendKey(keyCode: 1, modifiers: [.command])
        }
        ShortcutRailButton(chord: "⌘W", label: "Close", accessibilityLabel: "Close window") {
            sendKey(keyCode: 13, modifiers: [.command])
        }
        ShortcutRailButton(chord: "⌘Q", label: "Quit", accessibilityLabel: "Quit active application") {
            confirmsQuitApplication = true
        }
    }

    /// The navigation keys, below the fold on the rail.
    ///
    /// Worth having permanently, not worth the top of the rail: they are reached for in bursts —
    /// nudging around a form, moving through a menu — while the buttons above them are reached
    /// for continuously. They are what the rail's scrolling is for.
    @ViewBuilder
    var navigationButtons: some View {
        RailButton(icon: "chevron.up", label: "Up") { sendKey(keyCode: 126) }
        RailButton(icon: "chevron.down", label: "Down") { sendKey(keyCode: 125) }
        RailButton(icon: "chevron.left", label: "Left") { sendKey(keyCode: 123) }
        RailButton(icon: "chevron.right", label: "Right") { sendKey(keyCode: 124) }
        RailButton(icon: "delete.backward", label: "Delete") { sendKey(keyCode: 51) }
    }

    /// How tall a landscape rail may grow before its buttons scroll.
    ///
    /// Bounded by the pointer column at the foot of the same edge: the rail and that column share
    /// the right of the screen, and a rail allowed to run its full height would sit behind the
    /// joystick and the key stacked above it.
    ///
    /// Measured against the height the *chrome* is laid out in, not the canvas. The canvas ignores
    /// the safe area and the chrome does not, so the two differ by the home-indicator strip —
    /// sizing the rail against the larger number made it exactly that much too tall, and its last
    /// button ended up tucked under the return key.
    func railMaxHeight(in availableHeight: CGFloat) -> CGFloat {
        guard availableHeight > 0 else { return .infinity }
        let pointerColumn = ChromeMetrics.quickKeySize + ChromeMetrics.panelGap + joystickRadius * 2
        let reserved = pointerColumn
            + ChromeMetrics.bottomInset
            + ChromeMetrics.edgeInset * 2
            + ChromeMetrics.panelGap
        return max(160, availableHeight - reserved)
    }

    /// How tall an open panel may grow before its contents have to scroll.
    ///
    /// A panel is laid out above the controls and grows upward, so an unbounded one on a short
    /// screen pushes its own first row off the top — out of reach, and with nothing on screen to
    /// suggest it was ever there. Bounded against the height the chrome is laid out in for the
    /// same reason ``railMaxHeight(in:)`` is: the canvas ignores the safe area and the chrome
    /// does not.
    func ceiling(_ available: CGSize, _ isLandscape: Bool) -> CGFloat {
        guard available.height > 0 else { return .infinity }
        // A ceiling, not a target. The panel is as tall as its contents and no taller; this only
        // stops a pathological number of screens from pushing the panel's own first row off the
        // top of the display, where it would be both invisible and unreachable.
        //
        // What it has to stay clear of differs by orientation, and that is the whole reason this
        // takes a flag. In landscape the panel is drawn *over* the wheel and the pointer column,
        // so only the status pill above it needs room. In portrait it is stacked above them and
        // they are tall — the pointer column alone is 168 points, the dock another 70 — so they
        // are reserved, or the panel would cover controls that are still meant to be usable.
        //
        // Over-reserving in landscape is what kept the desktop tiles small: the ceiling was 279
        // points, two rows of chips and captions take 144 of it, and what was left made a tile 108
        // points wide however much width the panel had going spare.
        let reserved: CGFloat
        if isLandscape {
            reserved = ChromeMetrics.edgeInset * 2 + Self.statusBarHeight
        } else {
            // The dock and the pill, and not the pointer. The pointer sits above the dock now
            // rather than on the screen's own centre, so it is under the panel wherever the panel
            // ends — but it is not reserved either way, and that is the same decision as before
            // rather than a consequence of the move: the stick is drawn *under* the panel, so a
            // panel that covers it is one tap from being dismissed, while a panel kept clear of
            // it would be a panel too short to read.
            //
            // The *open* dock is reserved rather than the shut one, so that opening it while a
            // panel is up does not push the panel's own first row off the top of the display.
            reserved = ChromeMetrics.dockExpandedHeight
                + ChromeMetrics.panelGap
                + ChromeMetrics.edgeInset * 2
                + Self.statusBarHeight
        }
        return max(140, available.height - reserved)
    }

    /// The width a floating panel's contents have to work with.
    ///
    /// Worked out here rather than measured inside the panel: measuring it there made the number
    /// depend on the thing being sized, which is how the desktop tiles came out the same size as
    /// before the change that was supposed to grow them.
    func panelContentWidth(_ available: CGSize) -> CGFloat {
        max(min(Self.panelWidth, available.width) - 20, 0)
    }

    /// The status pill, which is the one thing a panel must not be drawn over the top of.
    static let statusBarHeight: CGFloat = 44

    var settingsButton: some View {
        RailButton(icon: "gearshape", label: "Settings", selected: openPanel == .settings) {
            withAnimation(Motion.settle) { openPanel = openPanel == .settings ? nil : .settings }
        }
    }

    /// The one floating panel, whichever it is.
    ///
    /// One place, because four panels across two orientations is eight arrangements to keep in
    /// step, and the difference between them is what they contain rather than how they are framed.
    @ViewBuilder
    func floatingPanel(_ available: CGSize, isLandscape: Bool) -> some View {
        // `alignment: .bottom` on every one of these, and it is load-bearing rather than tidy.
        // `maxHeight` makes a view *flexible* up to that height, so a panel whose contents are
        // shorter than the ceiling — the shortcuts panel nearly always — grows to the ceiling and
        // centres its contents inside it. Bottom-aligned, the frame is still the ceiling but the
        // panel sits at the bottom of it, which is where a panel belongs.
        switch openPanel {
        case .shortcuts:
            shortcutsPanel
                .frame(maxWidth: Self.panelWidth, maxHeight: ceiling(available, isLandscape), alignment: .bottom)
        case .desktops:
            DesktopsPanel(
                chromeFrames: $chromeFrames,
                onSelect: closePanelAfterSelection,
                maximumHeight: ceiling(available, isLandscape),
                contentWidth: panelContentWidth(available)
            )
            .frame(maxWidth: Self.panelWidth, maxHeight: ceiling(available, isLandscape), alignment: .bottom)
        case .sources:
            SourcesPanel(chromeFrames: $chromeFrames, onSelect: closePanelAfterSelection)
                .frame(maxWidth: Self.panelWidth, maxHeight: ceiling(available, isLandscape), alignment: .bottom)
        case .settings:
            SettingsPanel(chromeFrames: $chromeFrames) {
                withAnimation(Motion.settle) { openPanel = .sources }
            }
            .frame(maxWidth: Self.panelWidth, maxHeight: ceiling(available, isLandscape), alignment: .bottom)
        case nil:
            EmptyView()
        }
    }

    /// The widest a floating panel may be. Wide enough for a source picker's names and icons to be
    /// scanned, narrow enough that it stays clear of the rails on a phone held sideways.
    static let panelWidth: CGFloat = 520

    /// Puts the panel away once the user has picked something from it, if that is what they asked
    /// for.
    ///
    /// Shortcuts is exempt and always will be, whatever the setting says: its buttons are momentary
    /// key presses rather than choices, and a panel that shut after every keystroke would have to
    /// be reopened for the next one.
    func closePanelAfterSelection() {
        guard hidesPanelAfterSelect else { return }
        withAnimation(Motion.settle) { openPanel = nil }
    }

    /// Return, beside the pointer rather than inside the shortcuts panel — see ``QuickKeyButton``
    /// for why it earns a permanent place. The arrow strip in the panel keeps its own copy: that
    /// one is for when the user is already in there moving around a window.
    var returnKey: some View {
        // Captioned "Enter" and not "Return", though the key it sends is Return — see
        // ``SessionModel/pressReturn()``. The caption's job is to be the word the user reaches for,
        // and on a phone this key is Enter to everyone who is not reading Apple's keyboard
        // documentation. The spoken name matches the visible one, so VoiceOver agrees with the
        // screen.
        QuickKeyButton(icon: "return", label: "Enter", caption: "Enter") { model.pressReturn() }
    }

    /// Back, to the left of the pointer.
    ///
    /// ⌘← — an arrow rather than the bracket, and that choice is the whole point of this comment.
    ///
    /// ⌘[ is the other spelling of Back and the one that first went here, and it does not work
    /// everywhere: an arrow key reports the same key code on every keyboard layout, while `[`
    /// is matched by the *character* the key produces, so on a layout that puts the bracket
    /// behind a modifier the shortcut never fires. Back is ⌘← in Safari, Chrome, Finder and
    /// System Settings alike, and the arrow cannot be misread by a layout.
    ///
    /// A remote desktop has no history of its own to walk, so the only honest thing this button
    /// can mean is what the Mac under it already means by Back.
    ///
    /// Smaller than Return and off its axis, because it is not the key that commits: it is the
    /// one reached for in passing, so it sits beside the stick rather than above it.
    var backKey: some View {
        QuickKeyButton(icon: "chevron.backward", label: "Back", size: 46, caption: "Back") {
            sendKey(keyCode: 123, modifiers: [.command])
        }
    }

    /// Return above the pointer, Delete beside it.
    ///
    /// Trailing-aligned, with the top row framed to the stick's own width, so Return stays on the
    /// stick's axis now that the column is wider than the pointer is. Centred in the column
    /// instead, it would sit off to the left of the thing it belongs to.
    ///
    /// Shared by both layouts rather than written twice: the two used to be copies of each other,
    /// which is how a control ends up in one orientation and not the other.
    var pointerColumn: some View {
        VStack(alignment: .trailing, spacing: ChromeMetrics.panelGap) {
            returnKey
                .frame(width: joystickRadius * 2)
            HStack(alignment: .bottom, spacing: ChromeMetrics.panelGap) {
                backKey
                joystick()
            }
        }
    }

    func joystick(radius: CGFloat = joystickRadius) -> some View {
        JoystickView(
            onMove: sendJoystick,
            onTap: sendJoystickClick,
            onRightClick: sendJoystickRightClick,
            onDoubleTap: changePointerSpeed,
            speedText: speedBadge,
            pointSize: model.capturePointSize,
            radius: radius
        )
    }

    /// Steps the pointer's speed and says so on the pad for a moment.
    ///
    /// The badge is the only feedback there is. A double tap that changes a number the user
    /// cannot see is a gesture they would have to take on trust, and the joystick is the one
    /// control with nowhere to print the current value — so it shows what it just became, and
    /// then stops.
    func changePointerSpeed() {
        withAnimation(Motion.tap) { model.cyclePointerSpeed() }
        speedBadge = model.pointerSpeedLabel
        speedBadgeTask?.cancel()
        speedBadgeTask = Task {
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.tap) { speedBadge = nil }
        }
    }

    /// How far the pointer column sits past the rail's edge inset.
    ///
    /// Centred on the rail above it, which is what "in line" means here. The pointer is a 100pt
    /// circle and a rail is 64pt wide, so aligning their trailing edges — which the shared edge
    /// inset does on its own — leaves the two centres 18pt apart, and an 18pt disagreement down
    /// a column reads as the whole bottom of the screen being askew.
    ///
    /// Applied to the whole column rather than to the joystick alone, so the key stacked above it
    /// stays centred on the same axis.
    var joystickColumnOffset: CGFloat {
        (joystickRadius * 2 - ChromeMetrics.panelWidth) / 2
    }

    /// The one panel: everything that is not worth a permanent button.
    ///
    /// One panel rather than four, and only ever one open at a time. Having several that could
    /// be up at once, with no rule about which won, was most of what made the old screen feel
    /// like it was moving under the user.
}
