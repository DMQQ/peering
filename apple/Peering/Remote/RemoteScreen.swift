import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

/// Must agree with the horizontal offset that centres it on the rail, and with the centring of the
/// key stacked on top of it.
let joystickRadius: CGFloat = 50

struct RemoteScreen: View {
    @Environment(SessionModel.self) var model
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) var verticalSizeClass

    @State var streamLooksPaused = false
    @State var dictation = VoiceDictation()
    @State var shortcutsDrag: CGFloat = 0
    @State var keyRowsHeight: CGFloat = 0
    @State var panelDrag: CGFloat = 0
    @AppStorage(PreferenceKeys.keyboardShortcutsExpanded) var shortcutsExpanded = false
    /// 0 with the shortcut keys folded away and 1 with them shown, following the finger while the handle is dragged.
    var shortcutsProgress: CGFloat {
        let settled: CGFloat = shortcutsExpanded ? 1 : 0
        guard keyRowsHeight > 0 else { return settled }
        return min(1, max(0, settled - shortcutsDrag / keyRowsHeight))
    }
    var shortcutsCollapsed: Bool { shortcutsProgress < 0.5 }

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
    @State var showsModePicker = false
    @State var watching: ChatWatch?

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

    private var dueScreenTours: [Tour] {
        guard model.phase == .ready, !showsLandscapeHint, !hasSeenTourScreen else { return [] }
        return [.screen]
    }

    var deviceIsLandscape: Bool { DeviceScene.isLandscape }

    var body: some View {
        NavigationStack(path: pushedRoute) {
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
        .overlay { hubSplit }
        .overlay { backToChat }
        .animation(Motion.settle, value: watching)
        .environment(\.watchOnMac, { watchOnMac(from: $0) })
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
                // Above the gesture surface, which otherwise takes every tap meant for the window's buttons.
                windowControls
                remoteNoticeLayer
                mosaicDismissButtons
                sessionChrome(isLandscape: isLandscape, available: proxy.size)
                modeLayers

                if case .confirming(let code) = model.phase {
                    PairingPrompt(code: code, hostName: model.shownHostName ?? String(localized: "this Mac"))
                }

                // **`isBeingPutBack`, not `isResumingAfterDrop`.** The narrower flag needs
                // `hasBeenReady`, which is carried from the session object a warm reconnect replaces
                // but a cold launch has no such object, so `hasBeenReady` starts false and stays
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
            resolveSessionMode()
            presentLandscapeHint()
        }
        .onChange(of: model.activeSessionID) { _, _ in
            endWatchIfMacChanged()
            resolveSessionMode()
        }
        .onChange(of: route) { _, route in
            leaveWorkspaceIfClosed(route)
            endWatchIfHubOpened(route)
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
            model.hostPlatform == .mac ? "Quit the active Mac app?" : "Close the active app?",
            isPresented: $confirmsQuitApplication,
            titleVisibility: .visible
        ) {
            Button(model.hostPlatform == .mac ? "Send ⌘Q" : "Send Alt+F4", role: .destructive) {
                quitActiveApplication()
            }
        } message: {
            Text(model.hostPlatform == .mac ? "The Mac may ask you to save open documents first." : "The app may ask you to save open documents first.")
        }
        .onChange(of: model.frameArrived) { _, _ in endTransitionIfReady() }
    }

    // MARK: - Keyboard input bar
}
