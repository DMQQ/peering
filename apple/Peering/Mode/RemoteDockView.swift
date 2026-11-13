import PeeringKit
import RemoteCore
import SwiftUI

/// The remote with no picture: a pad for the pointer, the clicks, a few keys, and the Mac's own Spaces and lock.
struct RemoteDockView: View {
    @Environment(SessionModel.self) private var model
    /// Held by reference: a struct in @State rebuilt the whole dock on every move of a drag.
    @State private var engineBox = RemoteDockEngineBox()
    @State private var touch = RemoteDockTouch()
    @State private var ripple: RemoteDockRipple?
    @State private var openPanel: RemoteDockPanel?
    @State private var padFillsScreen = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 12) {
                pad
                if !padFillsScreen {
                    // Only the shut dock's room: opening it or a panel draws over the pad rather than shrinking it.
                    Color.clear.frame(height: RemoteDockControls.restingHeight)
                }
            }
            if !padFillsScreen, !model.showKeyboard {
                RemoteDockControls(
                    desktops: desktops,
                    actions: controlActions,
                    openPanel: openPanel,
                    panel: panelContent,
                    onClosePanel: closePanel
                )
            }
        }
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.top, 8)
        .padding(.bottom, ChromeMetrics.edgeInset)
        // The typing bar floats over the pad: reaching the screen's edge keeps its inset from shrinking the pad.
        .ignoresSafeArea(.container, edges: model.showKeyboard ? .bottom : [])
        .background(ColorPalette.backdrop.ignoresSafeArea())
        // A report lags the moves this pad just sent, so taking it mid-swipe snapped the pointer back to where it was and only taps seemed to work. Only a pointer moved on the Mac itself, while the pad is idle, is adopted.
        .onChange(of: model.hostPointer, initial: true) { _, reported in
            guard touch.point == nil, Date.now.timeIntervalSince(touch.lastMoveAt) > 0.5 else { return }
            engineBox.engine.adopt(x: reported.point.x, y: reported.point.y)
        }
        .onDisappear {
            run(engineBox.engine.endDrag())
            model.showKeyboard = false
        }
    }

    private var hostID: String? { model.activeSession?.hostID }

    private var pad: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ZStack {
            RemoteDockTouchField(touch: touch, ripple: ripple)
            RemoteDockPad(actions: padActions)
        }
        .clipShape(shape)
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(Motion.settle) { padFillsScreen.toggle() }
            } label: {
                Image(systemName: padFillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .frame(width: 36, height: 36)
                    .glassSurface(in: Circle(), interactive: true)
            }
            .buttonStyle(RailButtonStyle(scale: 0.9, haptic: true))
            .padding(8)
            .accessibilityLabel(padFillsScreen ? String(localized: "Exit full screen") : String(localized: "Full screen"))
        }
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .frame(maxHeight: .infinity)
    }

    private func toggle(_ panel: RemoteDockPanel) {
        withAnimation(Motion.settle) {
            openPanel = openPanel == panel ? nil : panel
            if openPanel != nil { model.showKeyboard = false }
        }
    }

    private func closePanel() {
        withAnimation(Motion.settle) { openPanel = nil }
    }

    private var panelContent: AnyView? {
        switch openPanel {
        case .apps:
            hostID.map { AnyView(RemoteDockAppsPanel(hostID: $0, onClose: closePanel)) }
        case .shortcuts:
            AnyView(RemoteDockShortcutsPanel())
        case .desktops:
            AnyView(RemoteDockDesktopsPanel(onClose: closePanel))
        case nil:
            nil
        }
    }

    private var desktops: (count: Int, current: Int?)? {
        guard let display = model.catalog?.spaceInfo?.displays.first else { return nil }
        return (display.count, display.current)
    }

    private var controlActions: RemoteDockControlActions {
        RemoteDockControlActions(
            onKeyboard: { withAnimation(Motion.settle) { openPanel = nil; model.showKeyboard.toggle() } },
            onDesktops: { toggle(.desktops) },
            onApps: { toggle(.apps) },
            onShortcuts: { toggle(.shortcuts) },
            onKey: press
        )
    }

    private func swiped(_ swipe: TrackpadSwipe) {
        for command in swipe.commands(spaces: model.catalog?.spaceInfo) { model.send(command) }
    }

    private func press(_ key: RemoteDockKey) {
        model.send(.keyDown(keyCode: key.keyCode, modifiers: []))
        model.send(.keyUp(keyCode: key.keyCode, modifiers: []))
    }

    private var padActions: RemoteDockPadActions {
        RemoteDockPadActions(
            onMove: { touch.lastMoveAt = .now; run(engineBox.engine.move(dx: $0.width, dy: $0.height, padWidth: 1, padHeight: 1)) },
            onTap: { run(engineBox.engine.tap()) },
            onTwoFingerTap: { run(engineBox.engine.twoFingerTap()) },
            onScroll: { run(engineBox.engine.scroll(dx: $0.width, dy: $0.height)) },
            onDragBegin: { run(engineBox.engine.beginDrag()) },
            onDragEnd: { run(engineBox.engine.endDrag()) },
            onTouch: { touch.point = $0 },
            onPress: { ripple = RemoteDockRipple(point: $0, start: .now) },
            onSwipe: swiped
        )
    }

    private func run(_ events: [TrackpadEngine.Event]) {
        for event in events {
            switch event {
            case .move(let x, let y): model.send(.mouseMove(to: NormalizedPoint(x: x, y: y)))
            case .press(let right): model.send(.mouseDown(button: right ? .right : .left))
            case .release(let right): model.send(.mouseUp(button: right ? .right : .left))
            case .scroll(let dx, let dy): model.send(.scroll(dx: dx, dy: dy))
            }
        }
    }
}
