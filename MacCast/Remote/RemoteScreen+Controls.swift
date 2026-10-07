import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

struct QuickAction: Identifiable {
    let chord: String
    let label: String
    let accessibilityLabel: String
    let action: () -> Void

    var id: String { chord }
}

extension RemoteScreen {
    // MARK: - The six controls

    var modeButton: some View {
        RailButton(
            icon: interactionMode.symbol,
            label: interactionMode.label,
            selected: interactionMode != .control
        ) {
            withAnimation(Motion.settle) { interactionMode = interactionMode.toggled }
        }
    }

    var sourcesButton: some View {
        RailButton(
            icon: "rectangle.on.rectangle",
            label: String(localized: "Apps"),
            selected: openPanel == .sources
        ) {
            withAnimation(Motion.settle) { openPanel = openPanel == .sources ? nil : .sources }
        }
    }

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

    var keysButton: some View {
        RailButton(
            icon: model.showKeyboard ? "keyboard.fill" : "keyboard",
            label: String(localized: "Keyboard"),
            selected: model.showKeyboard
        ) { model.showKeyboard.toggle() }
    }

    var shortcutsButton: some View {
        RailButton(icon: "command", label: String(localized: "Shortcuts"), selected: openPanel == .shortcuts) {
            withAnimation(Motion.settle) {
                openPanel = openPanel == .shortcuts ? nil : .shortcuts
            }
        }
    }

    var clipboardButton: some View {
        RailButton(icon: "doc.on.clipboard", label: String(localized: "Clipboard"), selected: openPanel == .clipboard) {
            withAnimation(Motion.settle) {
                openPanel = openPanel == .clipboard ? nil : .clipboard
            }
        }
    }

    var escapeButton: some View {
        RailButton(icon: "escape", label: "Esc") { sendKey(keyCode: 53) }
    }

    var tabButton: some View {
        RailButton(icon: "arrow.right.to.line", label: "Tab") { sendKey(keyCode: 48) }
    }

    @ViewBuilder
    var landscapeQuickActions: some View {
        ForEach(quickActions) { quickAction in
            ShortcutRailButton(
                chord: quickAction.chord,
                label: quickAction.label,
                accessibilityLabel: quickAction.accessibilityLabel,
                action: quickAction.action
            )
        }
    }

    var quickActions: [QuickAction] {
        [
            QuickAction(chord: "⌘C", label: "Copy", accessibilityLabel: "Copy") {
                sendKey(keyCode: 8, modifiers: [.command])
            },
            QuickAction(chord: "⌘V", label: "Paste", accessibilityLabel: "Paste") {
                sendKey(keyCode: 9, modifiers: [.command])
            },
            QuickAction(chord: "⌘Z", label: String(localized: "Undo"), accessibilityLabel: String(localized: "Undo")) {
                sendKey(keyCode: 6, modifiers: [.command])
            },
            QuickAction(chord: "⌘X", label: "Cut", accessibilityLabel: "Cut") {
                sendKey(keyCode: 7, modifiers: [.command])
            },
            QuickAction(chord: "⌘Q", label: String(localized: "Quit"), accessibilityLabel: String(localized: "Quit active application")) {
                confirmsQuitApplication = true
            },
        ]
    }

    @ViewBuilder
    var navigationButtons: some View {
        ForEach(DockControl.navigation) { control in
            dockControlView(control)
        }
    }

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

    func ceiling(_ available: CGSize, _ isLandscape: Bool) -> CGFloat {
        guard available.height > 0 else { return .infinity }
        // What it has to stay clear of differs by orientation, and that is the whole reason this
        // takes a flag. In landscape the panel is drawn *over* the wheel and the pointer column,
        // so only the status pill above it needs room. In portrait it is stacked above them and
        // they are tall — the pointer column alone is 168 points, the dock another 70 — so they
        // are reserved, or the panel would cover controls that are still meant to be usable.
        //
        // Reaching for the larger reserve in landscape is a mistake worth naming, because it
        // looks like the safe one. It is not: the ceiling is what a panel's contents are squeezed
        // into, and a panel that reserves for controls it is drawn *over* is a panel whose
        // contents are too short. That is what once held the desktop grid's tiles down to the
        // minimum however much width they had going spare.
        let reserved: CGFloat
        if isLandscape {
            reserved = ChromeMetrics.edgeInset * 2 + Self.statusBarHeight
        } else {
            // The *open* dock is reserved rather than the shut one, so that opening it while a
            // panel is up does not push the panel's own first row off the top of the display.
            // ``ChromeMetrics/dockStandingHeight`` rather than the card's height, because the
            // dots under the card are part of what is standing on the picture.
            reserved = ChromeMetrics.dockStandingHeight
                + ChromeMetrics.panelGap
                + ChromeMetrics.edgeInset * 2
                + Self.statusBarHeight
        }
        return max(140, available.height - reserved)
    }

    static let statusBarHeight: CGFloat = 44

    var settingsButton: some View {
        RailButton(icon: "gearshape", label: String(localized: "Settings"), selected: openPanel == .settings) {
            withAnimation(Motion.settle) { openPanel = openPanel == .settings ? nil : .settings }
        }
    }

    @ViewBuilder
    func floatingPanel(_ available: CGSize, isLandscape: Bool) -> some View {
        // `alignment: .bottom` on every one of these, and it is load-bearing rather than tidy.
        // `maxHeight` makes a view *flexible* up to that height, so a panel whose contents are
        // shorter than the ceiling — the shortcuts panel nearly always — grows to the ceiling and
        // centres its contents inside it. Bottom-aligned, the frame is still the ceiling but the
        // panel sits at the bottom of it, which is where a panel belongs.
        if let panel = openPanel {
            ZStack(alignment: .bottom) {
                panelContent(panel)
                    .frame(maxWidth: .infinity)
                    .geometryGroup()
                    .id(panel)
                    .transition(.blurReplace(.downUp))
            }
            .matchedGeometryEffect(id: "surface", in: floatingSurface)
            .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 10)
            .reportChromeFrame(.panel, into: $chromeFrames)
            .frame(maxWidth: Self.panelWidth, maxHeight: ceiling(available, isLandscape), alignment: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func panelContent(_ panel: Panel) -> some View {
        switch panel {
        case .shortcuts:
            shortcutsPanel
        case .clipboard:
            ClipboardPanel(chromeFrames: $chromeFrames)
        case .sources:
            SourcesPanel(
                chromeFrames: $chromeFrames,
                onSelect: closePanelAfterSelection,
                onReturnToMosaic: animateBackToMosaic
            )
        case .settings:
            SettingsPanel(chromeFrames: $chromeFrames) {
                withAnimation(Motion.settle) { openPanel = .sources }
            }
        }
    }

    static let panelWidth: CGFloat = 520

    /// One place, because two things ask: the panel opening, and a session coming up while the panel
    /// is already on screen. Neither host keeps these pictures for long — they are taken on demand
    /// and pruned against the sources the Mac is offering now — so a reconnect to a Mac that has
    /// been relaunched in between is a grid of outlines until something asks again.
    func stopWatchingSourcePictures() {
        if model.hostSupportsSourceThumbnails {
            model.send(.watchSourceThumbnails(false))
        }
    }

    func askForSourcePictures() {
        guard openPanel == .sources else { return }
        if model.hostSupportsSourceThumbnails {
            model.send(.watchSourceThumbnails(true))
        }
        if let info = model.catalog?.spaceInfo, SourcesPanel.showsDesktops(info) {
            model.send(.refreshSpacePreviews)
        }
    }

    static let desktopRefreshInterval: Duration = .seconds(4)

    /// **Not ``askForSourcePictures()``.** That one also asks for a photograph of every window the
    /// Mac is offering, which is a capture per window. Window pictures do not go stale while the
    /// panel is up unless something changes on the Mac, and every window event there invalidates
    /// them anyway; the desktops are the ones that change under the user, and they are what a tile
    /// in this grid is drawn from.
    func askForFreshDesktops() {
        guard openPanel == .sources else { return }
        guard let info = model.catalog?.spaceInfo, SourcesPanel.showsDesktops(info) else { return }
        model.send(.refreshSpacePreviews)
    }

    /// Shortcuts is exempt and always will be, whatever the setting says: its buttons are momentary
    /// key presses rather than choices, and a panel that shut after every keystroke would have to
    /// be reopened for the next one.
    func closePanelAfterSelection() {
        guard hidesPanelAfterSelect else { return }
        withAnimation(Motion.settle) { openPanel = nil }
    }

    var returnKey: some View {
        QuickKeyButton(icon: "return", label: "Enter", caption: "Enter") { model.pressReturn() }
    }

    /// ⌘[ is the other spelling of Back and the one that first went here, and it does not work
    /// everywhere: an arrow key reports the same key code on every keyboard layout, while `[`
    /// is matched by the *character* the key produces, so on a layout that puts the bracket
    /// behind a modifier the shortcut never fires. Back is ⌘← in Safari, Chrome, Finder and
    /// System Settings alike, and the arrow cannot be misread by a layout.
    var backKey: some View {
        QuickKeyButton(icon: "chevron.backward", label: String(localized: "Back"), size: 46, caption: String(localized: "Back")) {
            sendKey(keyCode: 123, modifiers: [.command])
        }
    }

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

    /// iPhone it has somewhere safe to land: the landscape camera-housing safe area on that edge
    /// absorbs it. An iPad's landscape safe area carries no such margin, so the same push there
    /// carried the column straight past the physical edge of the display, which is the bug this
    /// idiom check exists to avoid. `UIDevice`'s idiom rather than the horizontal size class,
    /// because a Pro Max in landscape is `.regular` too and still has the housing margin the
    /// centring depends on.
    var joystickColumnOffset: CGFloat {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return 0 }
        return (joystickRadius * 2 - ChromeMetrics.panelWidth) / 2
    }

}
