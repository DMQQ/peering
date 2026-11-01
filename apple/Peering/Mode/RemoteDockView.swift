import PeeringKit
import RemoteCore
import SwiftUI

/// The remote with no picture: a pad for the pointer, the clicks, a few keys, and the Mac's own Spaces and lock.
struct RemoteDockView: View {
    @Environment(SessionModel.self) private var model
    let onSwitchMode: () -> Void
    let onShowScreen: () -> Void

    @State private var engine = TrackpadEngine()
    @State private var touch: CGPoint?
    @State private var ripple: RemoteDockRipple?
    @State private var lastMoveAt = Date.distantPast
    @State private var typed = ""
    @FocusState private var typing: Bool
    @State private var showsApps = false
    @State private var showsShortcuts = false
    @State private var showsDesktops = false
    /// The field is made before it is focused: focusing a field that does not exist yet does nothing.
    @State private var showsTypingField = false
    @State private var padFillsScreen = false
    @State private var keyboardHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 12) {
            if !padFillsScreen {
                header
            }
            pad
            if !padFillsScreen {
                if showsTypingField { typingField }
                RemoteDockControls(typing: showsTypingField, desktops: desktops, actions: controlActions)
            }
        }
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.top, 24)
        .padding(.bottom, 10)
        .sheet(isPresented: $showsApps) {
            if let hostID {
                RemoteDockAppsSheet(hostID: hostID)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showsShortcuts) {
            RemoteDockShortcutsSheet { shortcut in
                model.send(.keyDown(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))
                model.send(.keyUp(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers))
            }
            .presentationDetents([.fraction(0.72), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsDesktops) {
            RemoteDockDesktopsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // The session screen ignores the keyboard for the picture's sake, so the dock lifts itself or its typing field sits under the keys.
        .padding(.bottom, keyboardHeight)
        .background(ColorPalette.backdrop.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = UIScreen.main.bounds.height
            withAnimation(Motion.settle) { keyboardHeight = max(0, screen - frame.minY) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(Motion.settle) { keyboardHeight = 0 }
        }
        // A report lags the moves this pad just sent, so taking it mid-swipe snapped the pointer back to where it was and only taps seemed to work. Only a pointer moved on the Mac itself, while the pad is idle, is adopted.
        .onChange(of: model.hostPointer, initial: true) { _, reported in
            guard touch == nil, Date.now.timeIntervalSince(lastMoveAt) > 0.5 else { return }
            engine.adopt(x: reported.point.x, y: reported.point.y)
        }
        .onDisappear { run(engine.endDrag()) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            TabScreenHeader(model.shownHostName ?? String(localized: "this Mac"))
            .lineLimit(1)
            HStack(spacing: 0) {
                headerButton("macwindow", label: String(localized: "Screen"), action: onShowScreen)
                headerButton("square.grid.2x2", label: String(localized: "Change how you use this Mac"), action: onSwitchMode)
            }
            .padding(.horizontal, 4)
            .glassSurface(in: Capsule(), interactive: true)
        }
        .foregroundStyle(ColorPalette.ink)
        .padding(.top, 8)
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(RailButtonStyle(scale: 0.9, haptic: true))
        .accessibilityLabel(label)
    }

    private var hostID: String? { model.activeSession?.hostID }

    private var pad: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ZStack {
            RemoteDockDotField(touch: touch, ripple: ripple)
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

    private var desktops: (count: Int, current: Int?)? {
        guard let display = model.catalog?.spaceInfo?.displays.first else { return nil }
        return (display.count, display.current)
    }

    private var controlActions: RemoteDockControlActions {
        RemoteDockControlActions(
            onKeyboard: { withAnimation(Motion.settle) { showsTypingField = true } },
            onDesktops: { showsDesktops = true },
            onApps: { showsApps = true },
            onShortcuts: { showsShortcuts = true },
            onLock: { model.lockMac() },
            onKey: press
        )
    }

    /// Shown while typing so the keys have somewhere visible to land; each keystroke still goes straight to the Mac.
    private var typingField: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "Type to the Mac"), text: $typed)
                .focused($typing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.return)
                .onChange(of: typed) { old, new in sendTyping(from: old, to: new) }
                .onSubmit {
                    press(.returnKey)
                    typed = ""
                    typing = true
                }
            Button { typing = false } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ColorPalette.ink)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(RailButtonStyle(scale: 0.9, haptic: true))
            .accessibilityLabel(String(localized: "Hide keyboard"))
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .frame(height: 52)
        .glassSurface(in: Capsule(), interactive: true)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear { typing = true }
        .onChange(of: typing) { _, focused in
            if !focused { withAnimation(Motion.settle) { showsTypingField = false } }
        }
    }

    private func sendTyping(from old: String, to new: String) {
        if new.count > old.count {
            model.handleTypedText(String(new.dropFirst(old.count)))
        } else if new.count < old.count {
            for _ in 0..<(old.count - new.count) { press(.delete) }
        }
        if new.count > 200 { typed = "" }
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
            onMove: { lastMoveAt = .now; run(engine.move(dx: $0.width, dy: $0.height, padWidth: 1, padHeight: 1)) },
            onTap: { run(engine.tap()) },
            onTwoFingerTap: { run(engine.twoFingerTap()) },
            onScroll: { run(engine.scroll(dx: $0.width, dy: $0.height)) },
            onDragBegin: { run(engine.beginDrag()) },
            onDragEnd: { run(engine.endDrag()) },
            onTouch: { touch = $0 },
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
