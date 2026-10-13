import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

/// Must agree with the horizontal offset that centres it on the rail, and with the centring of the
/// key stacked on top of it.
let joystickRadius: CGFloat = 50

struct RemoteScreen: View {
    @Environment(SessionModel.self) var model

    @State var streamLooksPaused = false
    @State var dictation = VoiceDictation()
    @AppStorage(PreferenceKeys.keyboardShortcutsExpanded) var shortcutsExpanded = false
    var shortcutsCollapsed: Bool { !shortcutsExpanded }

    @AppStorage(PreferenceKeys.interactionMode) var interactionMode: InteractionMode = .control

    @AppStorage(PreferenceKeys.scalesToFill) var scalesToFill = false

    @State var zoom: CGFloat = 1
    @State var pan: CGSize = .zero
    @State var canvasSize: CGSize = .zero
    @State var remoteCursor = NormalizedPoint(x: 0.5, y: 0.5)
    @State var lastJoystickInput: MonotonicStamp?
    @AppStorage(PreferenceKeys.hidesPanelAfterSelect) var hidesPanelAfterSelect = true

    @State var showsLandscapeHint = false
    @State var landscapeHintTask: Task<Void, Never>?

    @AppStorage(PreferenceKeys.hasSeenLandscapeHint) var hasSeenLandscapeHint = false

    @AppStorage(PreferenceKeys.hasSeenTourScreen) var hasSeenTourScreen = false

    @State var rotationRefused = false

    @State var openPanel: Panel?
    @State var showsKeyboardBar = false
    @Namespace var floatingSurface
    @State var statusBarExpanded = true
    @State var openedStatusBarForReadySession = false
    @State var collapsedBarWidth: CGFloat = 0
    @State var dockExpanded = false
    @State var applicationDockIsUp = false
    @State var isImmersive = false
    @State var dockPreviews = ThumbnailImages()
    @State var dockPage: String?
    @State var statusBarCollapseTask: Task<Void, Never>?
    /// Unlike copy or paste, `⌘Q` can discard unsaved work, so the permanent button asks once
    /// before sending the chord.
    @State var confirmsQuitApplication = false
    @State var route: [RemoteRoute] = []

    var showsTerminals: Bool {
        get { !route.isEmpty }
        nonmutating set { route = newValue ? (route.isEmpty ? [.hub] : route) : [] }
    }

    @State var speedBadge: String?
    @State var speedBadgeTask: Task<Void, Never>?

    /// The gesture surface is a UIKit view under SwiftUI's drawing, so a touch aimed at a button
    /// reaches it anyway, and a slide while pressing starts a drag on the Mac underneath.
    @State var chromeFrames: [ChromeRegion: CGRect] = [:]

    @State var transition: PictureTransition?

    @State var heldTile: Int?
    @State var targetTile: Int?
    @State var heldPoint: CGPoint?

    enum Panel {
        case shortcuts
        case clipboard
        case sources
        case settings
    }

    func presentLandscapeHint() {
        // The landscape half of this guard is load-bearing for the flag: nothing is marked when a
        // session comes up sideways, so a phone whose first sessions are all landscape is still owed
        // the hint and gets it the first time one comes up in portrait.
        guard !deviceIsLandscape, !hasSeenLandscapeHint else { return }
        hasSeenLandscapeHint = true

        withAnimation(Motion.settle) { showsLandscapeHint = true }

        landscapeHintTask?.cancel()
        landscapeHintTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            dismissLandscapeHint()
        }
    }

    func dismissLandscapeHint() {
        landscapeHintTask?.cancel()
        landscapeHintTask = nil
        withAnimation(Motion.settle) { showsLandscapeHint = false }
    }

    /// An app cannot read Rotation Lock, so the error handler is the only way to tell a locked phone
    /// from a working one. The card stops fading while the request is out, so the button cannot
    /// dismiss the thing it sits on.
    func rotateToLandscape() {
        landscapeHintTask?.cancel()
        landscapeHintTask = nil

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in
            // The handler is not guaranteed to be on the main actor, and it writes view state.
            Task { @MainActor in
                withAnimation(Motion.settle) { rotationRefused = true }
            }
        }
    }

    private var dueScreenTours: [Tour] {
        guard model.phase == .ready, !showsLandscapeHint, !hasSeenTourScreen else { return [] }
        return [.screen]
    }

    var deviceIsLandscape: Bool { DeviceScene.isLandscape }

    var body: some View {
        NavigationStack(path: $route) {
            screen
                .analyticsScreen(.session)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: RemoteRoute.self) { route in
                    switch route {
                    case .hub: TerminalPanel(route: $route)
                    case .step(let step): TerminalPanel(route: $route, step: step)
                    }
                }
        }
        // **The Mac's answer moves the screen, never the tap.** A new shell or chat has no id until the Mac says so; the note is cleared so it opens once.
        .onChange(of: model.newTerminalID) { _, id in
            guard let id else { return }
            model.newTerminalID = nil
            openCreated(.terminal(id))
        }
        .onChange(of: model.newAgentSessionID) { _, id in
            guard let id else { return }
            model.newAgentSessionID = nil
            openCreated(.chat(id))
        }
        .onChange(of: InAppBanner.shared.openRequest, initial: true) { _, _ in
            openFromBanner()
        }
    }

    private var screen: some View {
        // `Environment` gives the object but no projected value, so a local `@Bindable` is what the
        // keyboard view binds to.
        @Bindable var model = model
        // **Read so that this whole screen re-evaluates when a frame reaches the live layer.** The
        // tile edges, the names and the ✕ buttons of an arrangement ask whether ``transition`` has
        // ended, which is itself decided by a fact only the renderer knows, and the renderer is not
        // observable. Without this the arrangement's own drawing arrives when something unrelated
        // forces a pass. See ``SessionModel/frameArrived``.
        let _ = model.frameArrived
        return GeometryReader { proxy in
            let isLandscape = deviceIsLandscape
            ZStack {
                // Black, where every other screen uses the near-black backdrop: the video is
                // letterboxed on any screen that is not the Mac's own shape, and those bars sit
                // directly against whatever the Mac itself is showing in black. At 0.04 the join is
                // a visible edge that reads as the picture being inset in a panel; at zero the bars
                // and the video's own black are the same black.
                Color.black.ignoresSafeArea()

                video
                mosaicOverlay
                clientCursor
                carryingScrim
                gestures
                remoteNoticeLayer
                mosaicDismissButtons
                sessionChrome(isLandscape: isLandscape, available: proxy.size)

                if case .confirming(let code) = model.phase {
                    PairingPrompt(code: code, hostName: model.shownHostName ?? String(localized: "this Mac"))
                }

                // **`isBeingPutBack`, not `isResumingAfterDrop`.** The narrower flag needs
                // `hasBeenReady`, which is carried from the session object a warm reconnect replaces
                // — but a cold launch has no such object, so `hasBeenReady` starts false and stays
                // false for the whole of that resume. This overlay then showed on top of the header
                // pill's own "Reconnecting…", the two disagreeing about whether a resume was under
                // way. `isBeingPutBack` is the same question ``ContentView``'s connecting card
                // answers, and covers both cases: see ``MacSession/isBeingPutBack``.
                if (model.phase == .connecting || model.phase == .handshaking),
                   !model.isBeingPutBack {
                    ProgressOverlay(
                        title: model.phase == .connecting
                            ? String(localized: "Connecting…")
                            : String(localized: "Securing the connection…"),
                        detail: model.shownHostName
                    )
                }

                if showsLandscapeHint, !isLandscape {
                    LandscapeHint(
                        rotationRefused: rotationRefused,
                        onRotate: rotateToLandscape,
                        onDismiss: dismissLandscapeHint
                    )
                    .transition(.opacity)
                }
            }
            // On the stack rather than on a layer of its own: the tips are drawn around the pill,
            // the dock and the joystick, so this has to be an ancestor of all three. A `Color.clear`
            // on top of this stack would be over the picture and behind nothing.
            .firstRunTours(dueScreenTours) { $0.markSeen() }
            // The disc that leaves immersive mode is the one piece of chrome whose absence leaves a
            // region behind: it goes when it is pressed, and a region left over from it is a patch
            // of the picture that no longer takes touches. On the stack, which outlives it.
            .chromeFramePresence(.immersiveEscape, into: $chromeFrames, when: isImmersive)
        }
        // The keyboard must not resize the picture: a shrinking view moves every control the user
        // is aiming at.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsKeyboardBar {
                keyboardInputBar
                    .transition(.blurReplace(.downUp))
            }
        }
        // A hidden panel reports nothing, so its last frame would go on blocking touches in a
        // region that no longer has anything in it.
        .onChange(of: model.hostPointer) { _, reported in
            adoptHostPointer()
        }
        .onChange(of: model.phase, initial: true) { _, phase in
            guard phase == .ready else {
                abandonPictureTransit()
                return
            }
            presentLandscapeHint()
        }
        .onChange(of: interactionMode, initial: true) { _, mode in
            model.setObserveOnly(mode == .observe)
        }
        // A zoom and a pan are chosen for one picture and mean nothing against another. The picture
        // becomes a different one in exactly one place, and the model watches for it there. See
        // Not `initial: true`: the first picture of a session has no previous zoom to invalidate.
        .onChange(of: model.picture) { previous, current in
            guard let previous, let current else { return }
            reactToPictureChange(from: previous, to: current)
        }
        // Turning the phone re-asks for the arrangement: the canvas takes the screen's own shape, so
        // a rotation is a different layout with a different identifier, and the Mac goes on capturing
        // the one it was asked for before, which the app then reads as "not showing a mosaic". See
        // ``SessionModel/refreshMosaicForViewport()``.
        // The canvas is deliberately not what is watched: it also changes when the user adds a
        // window, and a second ask from here would rebuild the arrangement already being built.
        .onChange(of: deviceIsLandscape) { _, isLandscape in
            model.refreshMosaicForViewport()
            // Gated the same way the Apps panel's thumbnail request is: an unrecognised command
            // ends the session on a Mac built before it existed. See ``DeviceOrientationSupport``.
            if model.hostSupportsDeviceOrientation {
                model.send(.reportDeviceOrientation(isLandscape: isLandscape))
            }
        }
        // Here rather than on the pill: the pill is built in each orientation's own layout, so a
        // task on it restarted on every rotation and opened the pill again.
        // A task restarts every time the screen reappears, so coming back from the terminals stack opened the pill again: it is remembered that this ready session already did.
        .task(id: model.phase) {
            guard model.phase == .ready else {
                openedStatusBarForReadySession = false
                return
            }
            guard !openedStatusBarForReadySession else { return }
            openedStatusBarForReadySession = true
            expandStatusBar()
        }
        .onChange(of: openPanel) { previous, panel in
            if panel == nil { chromeFrames[.panel] = nil }
            switch panel {
            case .shortcuts: Analytics.panelOpened(.shortcuts)
            case .clipboard: Analytics.panelOpened(.clipboard)
            case .sources: Analytics.panelOpened(.sources)
            case .settings: Analytics.panelOpened(.settings)
            case nil: break
            }
            if panel == .sources { askForSourcePictures() }
            if previous == .sources, panel != .sources { stopWatchingSourcePictures() }
        }
        // Keyed on the panel, so closing it is what stops the loop.
        // One floating thing at a time: a panel and the keyboard each close the other.
        .onChange(of: openPanel) { _, panel in
            model.isPanelOpen = panel != nil || showsTerminals
            if panel != nil {
                model.showKeyboard = false
                withAnimation(Motion.settle) { showsKeyboardBar = false }
            }
        }
        .onChange(of: showsTerminals) { _, shown in
            model.isPanelOpen = shown || openPanel != nil
            if shown { Analytics.panelOpened(.terminals) }
            if shown { model.showKeyboard = false }
        }
        .onDisappear {
            // Covered by the hub is not gone: the hub counts as an open panel until it is popped.
            model.isPanelOpen = showsTerminals
            if openPanel == .sources { stopWatchingSourcePictures() }
        }
        .onChange(of: model.showKeyboard, initial: true) { _, shown in
            withAnimation(Motion.settle) {
                showsKeyboardBar = shown
                if shown { openPanel = nil }
            }
        }
        .task(id: openPanel) {
            guard openPanel == .sources, !isImmersive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.desktopRefreshInterval)
                guard !Task.isCancelled else { return }
                askForFreshDesktops()
            }
        }
        // **And again when a session comes up with the grid already on screen.** The ask above is
        // keyed on the panel opening, and a reconnect changes nothing about the panel: it stayed
        // open across the whole of it. What changed is the Mac on the other end, whose pictures of
        // its own windows do not survive a relaunch there, so the grid sat on its outlines until the
        // panel was closed and opened again.
        .onChange(of: model.phase) { _, phase in
            if phase == .ready { askForSourcePictures() }
        }
        .confirmationDialog(
            "Quit the active Mac app?",
            isPresented: $confirmsQuitApplication,
            titleVisibility: .visible
        ) {
            Button("Send ⌘Q", role: .destructive) {
                sendKey(keyCode: 12, modifiers: [.command])
            }
        } message: {
            Text("The Mac may ask you to save open documents first.")
        }
        .onChange(of: model.frameArrived) { _, _ in endTransitionIfReady() }
    }

    // MARK: - Keyboard input bar

    /// With the keyboard up, the dock and both rails are behind it, so nothing else on this screen can
    /// be pressed. Esc is the only way out of a Mac menu or a completion list and no iOS keyboard has
    /// one; Tab is how a Mac moves focus and completes. See ``ModifierBar``.
    private var keyboardKeyRow: some View {
        HStack(spacing: 8) {
            compactCapButton(icon: "keyboard.chevron.compact.down", large: true) { model.showKeyboard = false }
                .accessibilityLabel("Hide keyboard")
            ModifierBar()
            HStack(spacing: 6) {
                compactKeyButton(icon: "escape", keyCode: 53)
                    .accessibilityLabel("Escape")
                compactKeyButton(icon: "arrow.right.to.line", keyCode: 48)
                    .accessibilityLabel("Tab")
            }
            Spacer(minLength: 8)
            // Landscape leaves about 90pt between the system keyboard and the top of the screen, which a third row does not fit in.
            if deviceIsLandscape { arrowStrip(withReturn: false) }
            compactCapButton(icon: "return", filled: true, large: true) { model.pressReturn() }
                .accessibilityLabel("Enter")
        }
    }

    var keyboardInputBar: some View {
        VStack(spacing: 8) {
            if !dictation.isListeningUI { shortcutsHandle.padding(.top, -10).padding(.bottom, -6) }
            keyboardInputRow
            if !dictation.isListeningUI, !shortcutsCollapsed {
                VStack(spacing: 8) {
                    keyboardKeyRow
                    if !deviceIsLandscape { arrowStrip(withReturn: false) }
                }
                .transition(.blurReplace)
            }
        }
        .animation(Motion.settle, value: shortcutsExpanded)
        .padding(.horizontal, 14)
        .padding(.vertical, deviceIsLandscape ? 8 : 12)
        .matchedGeometryEffect(id: "surface", in: floatingSurface)
        .glassSurface(in: RoundedRectangle(cornerRadius: ChromeMetrics.cornerRadius, style: .continuous))
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.top, deviceIsLandscape ? 4 : ChromeMetrics.edgeInset)
    }

    private var keyboardInputRow: some View {
        ZStack {
            HStack(spacing: 8) {
                if shortcutsCollapsed {
                    compactCapButton(icon: "keyboard.chevron.compact.down") { model.showKeyboard = false }
                        .accessibilityLabel("Hide keyboard")
                }
                dictationButton
                keyboardField
                if shortcutsCollapsed {
                    compactCapButton(icon: "return", filled: true) { model.pressReturn() }
                        .accessibilityLabel("Enter")
                }
            }
            .opacity(dictation.isActive ? 0 : 1)
            .allowsHitTesting(!dictation.isActive)
            switch dictation.state {
            case .listening, .finishing, .stopped:
                DictationOverlay(dictation: dictation, finish: { dictation.finish() }, cancel: { dictation.cancel() })
            case .denied, .unavailable:
                DictationNotice(denied: dictation.state == .denied) { dictation.dismissMessage() }
            case .idle:
                EmptyView()
            }
        }
        .animation(Motion.settle, value: dictation.state)
    }

    /// A handle on the bar's top edge: tap it, or drag it up or down, to show or fold the shortcut keys.
    private var shortcutsHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.32))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .contentShape(Rectangle())
            .onTapGesture { toggleShortcuts() }
            .gesture(
                DragGesture(minimumDistance: 10).onEnded { drag in
                    let wantsExpanded = drag.translation.height < 0
                    if wantsExpanded != shortcutsExpanded { toggleShortcuts() }
                }
            )
            .accessibilityElement()
            .accessibilityLabel(shortcutsCollapsed ? String(localized: "Show shortcut keys", table: "Dictation") : String(localized: "Hide shortcut keys", table: "Dictation"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggleShortcuts() }
    }

    private func toggleShortcuts() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(Motion.settle) { shortcutsExpanded.toggle() }
    }

    private var dictationButton: some View {
        Button {
            dictation.start { [model] spoken in model.insertDictation(spoken) }
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .glassSurface(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.9, haptic: true))
        .accessibilityLabel(String(localized: "Dictate", table: "Dictation"))
    }

    private var keyboardField: some View {
        // **The field itself, and it is a real one.** It holds the sentence, so iOS gives it a caret
        // that can be moved and reports every edit as a range plus a replacement, which is what
        // makes correcting the middle of a line work.
        //
        // No height of its own, deliberately: the wrapper answers with the height the sentence
        // needs, so the field grows a line at a time and this bar rises with it.
        KeyboardTypingCapture(
            model: model,
            isLarge: shortcutsCollapsed,
            isFocused: Binding(
                get: { model.showKeyboard },
                set: { model.showKeyboard = $0 }
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            ColorPalette.backdrop.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

}
