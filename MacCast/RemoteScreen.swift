import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// The pointer's radius.
///
/// Must agree with the horizontal offset that centres it on the rail, and with the centring of the
/// key stacked on top of it.
let joystickRadius: CGFloat = 50

/// The remote desktop itself: picture, pointer, keyboard, and the controls for all three.
///
/// Split across `RemoteScreen+*.swift` extensions rather than kept as one file of two thousand
/// lines. Members below stay `internal` rather than `private`, since `private` is file-scoped and
/// would cut an extension off from state declared here.
struct RemoteScreen: View {
    @Environment(SessionModel.self) var model

    /// Set once a connected session has had no picture for a while. See ``pausedCardDelay``.
    @State var streamLooksPaused = false

    /// Persisted because observe mode's no-input promise must survive a relaunch.
    @AppStorage(PreferenceKeys.interactionMode) var interactionMode: InteractionMode = .control

    /// Whether the picture is scaled up to reach the screen's edges.
    ///
    /// Persisted: it is a property of the *source*, not of the moment.
    @AppStorage(PreferenceKeys.scalesToFill) var scalesToFill = false

    @State var zoom: CGFloat = 1
    @State var pan: CGSize = .zero
    @State var canvasSize: CGSize = .zero
    /// The position most recently commanded by this phone. Drawing it immediately keeps the
    /// pointer responsive even while the next video frame is still crossing the network.
    @State var remoteCursor = NormalizedPoint(x: 0.5, y: 0.5)
    /// Whether picking something from a floating panel puts the panel away.
    ///
    /// Persisted: a working style rather than a moment.
    @AppStorage(PreferenceKeys.hidesPanelAfterSelect) var hidesPanelAfterSelect = true

    /// Whether the turn-your-phone card is on screen right now, and the timer that takes it away
    /// again. See ``presentLandscapeHint()``.
    ///
    /// Session-scoped by design: `ContentView` builds this view fresh for every session. Whether the
    /// card has ever been shown is ``hasSeenLandscapeHint``, which outlives it.
    @State var showsLandscapeHint = false
    @State var landscapeHintTask: Task<Void, Never>?

    /// Whether the turn-your-phone card has been shown, ever.
    ///
    /// Written in exactly one place, ``presentLandscapeHint()``, at the moment the card goes up and
    /// never when it leaves: it leaves by rotation or by the timer, and neither runs a dismissal.
    @AppStorage(PreferenceKeys.hasSeenLandscapeHint) var hasSeenLandscapeHint = false

    /// Whether this screen's first-run tips have been seen. See ``Tour``.
    @AppStorage(PreferenceKeys.hasSeenTourScreen) var hasSeenTourScreen = false

    /// Set when iOS refused a rotation, which means Rotation Lock is on. Lasts as long as the
    /// session does, because the condition it describes does too.
    ///
    /// Deliberately not gated by ``hasSeenLandscapeHint``: an app cannot read Rotation Lock, so a
    /// refusal is the only evidence of it, and this answers a press the user just made rather than
    /// offering an unsolicited hint.
    @State var rotationRefused = false

    @State var openPanel: Panel?
    @State var statusBarExpanded = true
    /// The width of the bar while it is closed, which is the pill plus the four circles beside it.
    ///
    /// Read so that the panel opens into at least that much: the circles are laid out outside the
    /// pill, and removing them without this would let the bar grow shorter at the moment it opens,
    /// which is the opposite of the movement. Measured rather than added up because the pill is as
    /// wide as the Mac's name.
    @State var collapsedBarWidth: CGFloat = 0
    /// Whether the portrait dock has opened onto the controls that did not earn a permanent
    /// place in it. Portrait's alone: the landscape rails have the height to show them all.
    @State var dockExpanded = false
    /// Whether the landscape application strip has been asked for. See ``applicationDock``.
    ///
    /// Shut until somebody wants it, which is the whole of the design: the strip is pictures, and
    /// pictures standing on a picture are the one thing this screen cannot afford upright. Opening
    /// it is a gesture; closing it is the same gesture, a tap on the handle, or picking something.
    @State var applicationDockIsUp = false
    /// Whether the chrome is put away and the picture has the screen. See ``immersiveEscape``.
    ///
    /// Session-scoped rather than remembered: it is a way of looking at a Mac for a while, not a
    /// preference about sessions, and a session that came back with no controls on it would be a
    /// screen somebody has to work out how to leave.
    @State var isImmersive = false
    /// The dock's desktop pictures, decoded once each. See ``ThumbnailImages``.
    ///
    /// The dock's own, rather than the panel's: the panel is torn down and rebuilt every time it is
    /// opened, and the dock is on screen for as long as the orientation is. Two caches for two
    /// lifetimes, each of which would otherwise be the other's size.
    @State var dockPreviews = ThumbnailImages()
    /// Which sheet of the dock is showing, by ``DockSheet/id``.
    ///
    /// Optional because that is what `scrollPosition(id:)` binds to: a pager that has not settled
    /// reports nothing, and `nil` means the first sheet, which is where the pager already sits.
    @State var dockPage: String?
    /// The pending auto-collapse, so expanding by hand can cancel the one already in flight.
    @State var statusBarCollapseTask: Task<Void, Never>?
    /// Unlike copy or paste, `⌘Q` can discard unsaved work, so the permanent button asks once
    /// before sending the chord.
    @State var confirmsQuitApplication = false
    @State var showsTerminals = false

    /// What the joystick is showing about its own speed, for the second or so after it changes.
    @State var speedBadge: String?
    @State var speedBadgeTask: Task<Void, Never>?

    /// Where the window's own controls are, in the canvas's coordinates.
    ///
    /// The gesture surface is a UIKit view under SwiftUI's drawing, so a touch aimed at a button
    /// reaches it anyway, and a slide while pressing starts a drag on the Mac underneath.
    @State var chromeFrames: [ChromeRegion: CGRect] = [:]

    /// The picture on screen replacing another, if it is in the middle of doing that.
    ///
    /// One value for the whole of a change: a tile opening, an arrangement coming back, a source
    /// picked from a panel, a rotation's rebuilt canvas. See ``PictureTransition``.
    @State var transition: PictureTransition?

    /// The tile a long press is holding, and the slot the finger is over.
    ///
    /// The whole of a reorder's state, and the screen's because it is the only side that knows both
    /// the arrangement and where the picture is. The gesture surface reports a point; these are what
    /// that point means. See ``dropHeldTile()``.
    @State var heldTile: Int?
    @State var targetTile: Int?
    /// Where the finger holding it is, in the canvas's own coordinates.
    ///
    /// Without this the tile never leaves its place: the tile in hand is drawn here rather than
    /// around its slot, so the thing being moved is under the thumb that picked it up. The picture
    /// cannot follow, because the windows are one composited surface on the Mac, so what travels is
    /// the outline and the name. See ``MosaicOverlay``.
    @State var heldPoint: CGPoint?

    let minimumZoom: CGFloat = 0.5
    let maximumZoom: CGFloat = 8

    /// The one sliding panel.
    ///
    /// An enum rather than a boolean per panel, so "only one at a time" is true by construction.
    enum Panel {
        case shortcuts
        case clipboard
        case sources
        case settings
    }

    /// Shows the turn-your-phone card to a session that came up in portrait, once in the life of
    /// the install.
    ///
    /// Portrait is not a failure and the dock and joystick are built for it, but side-on is where
    /// the picture gets the whole display. The card spends three seconds saying so and is timed to
    /// get out of the way, and it is a one-off rather than a reminder: a user who has read it and
    /// stayed upright has answered it.
    ///
    /// The flag is written before the card is drawn, never when it goes away, because it usually
    /// leaves by rotation or by the timer and neither of those runs a dismissal.
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

    /// Asks iOS to turn the phone, which is the only help available to a user whose Rotation Lock
    /// is on.
    ///
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

    /// What this screen owes, and what it waits for.
    ///
    /// Three gates: the session has to be up, because the steps are drawn around a pill, a dock and
    /// a joystick that only exist once the picture does; the turn-your-phone card has to have gone,
    /// so that two things are not saying "look here" at once; and the flag has to say the tips are
    /// still owed.
    ///
    /// `showsLandscapeHint` needs no more than that: the card takes itself away after three seconds,
    /// and this is recomputed on every pass.
    private var dueScreenTours: [Tour] {
        guard model.phase == .ready, !showsLandscapeHint, !hasSeenTourScreen else { return [] }
        return [.screen]
    }

    /// Whether the phone is being held sideways.
    ///
    /// Everything that depends on the orientation reads it, and the reasoning for asking the scene
    /// for the orientation it is moving to lives with the one implementation.
    /// See ``DeviceScene/isLandscape``.
    var deviceIsLandscape: Bool { DeviceScene.isLandscape }

    var body: some View {
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
                // Over the picture and its borders, under the chrome, which is the app's own and
                // stays where it is. See ``carryingScrim``.
                carryingScrim
                gestures
                // Above the gesture surface, which is why it is a layer of its own: a tap on a tile
                // belongs to that surface, so a control drawn under it would never see a finger. See
                // ``mosaicDismissButtons``.
                mosaicDismissButtons
                sessionChrome(isLandscape: isLandscape, available: proxy.size)

                if case .confirming(let code) = model.phase {
                    PairingPrompt(code: code, hostName: model.hostName ?? "this Mac")
                }

                // The same decision the connecting card makes, and it has to be made in both
                // places the same way: the screen stays mounted for a resume, and a black veil with
                // a spinner over a picture that never left is the one thing a resume must not show.
                //
                // **`isBeingPutBack`, not `isResumingAfterDrop`.** The narrower flag needs
                // `hasBeenReady`, which is carried from the session object a warm reconnect replaces
                // — but a cold launch has no such object, so `hasBeenReady` starts false and stays
                // false for the whole of that resume. This overlay then showed on top of the header
                // pill's own "Reconnecting…", the two disagreeing about whether a resume was under
                // way. `isBeingPutBack` is the same question ``ContentView``'s connecting card
                // answers, and covers both cases: see ``MacSession/isBeingPutBack``.
                //
                // Pairing is deliberately not covered: a resumed session that somehow needs the six
                // digits has to be able to show them. See ``PairingPrompt`` just above.
                if (model.phase == .connecting || model.phase == .handshaking),
                   !model.isBeingPutBack {
                    ProgressOverlay(
                        title: model.phase == .connecting ? "Connecting…" : "Securing the connection…",
                        detail: model.hostName
                    )
                }

                // Hidden the moment the phone is turned, which is all it asks for. The timer keeps
                // running underneath and finds it already gone.
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
            if model.showKeyboard {
                keyboardInputBar
            }
        }
        .sheet(isPresented: $showsTerminals) {
            TerminalPanel()
                .presentationDetents([.large])
                // Swipe to dismiss is off: the terminal is a running process, and a swipe that
                // closes the sheet does not close the shell but looks like it did. Done is the one
                // deliberate way out.
                .interactiveDismissDisabled()
                // The locks inside this sheet need a presenter inside it: a paywall asked for from
                // here and presented from the root is a tap that does nothing.
                .presentsPaywall(model)
        }
        // A hidden panel reports nothing, so its last frame would go on blocking touches in a
        // region that no longer has anything in it.
        // Keyed to the phase rather than to appearing, because a session does not arrive ready: the
        // screen is up during `.confirming` and the picture only starts at `.ready`, which is the
        // moment worth interrupting.
        //
        // **A transition waiting on an app that was not there.** `Task.sleep` does not run while
        // the app is suspended, so a transition still in flight when it was backgrounded is still
        // in flight, frozen snapshot and all, when it comes back — which is the honest state to
        // return to rather than one this needs to hurry. Nothing to force here any more: the same
        // deadline that bounds a transition made while the app was in the foreground goes on
        // bounding it now, and the frame that was waited for either arrived while the app was away
        // (in which case ``endTransitionIfReady()`` has already run) or is still on its way.
        .onChange(of: model.phase, initial: true) { _, phase in
            guard phase == .ready else {
                // **A movement does not outlive the connection it was measuring.** The view is kept
                // across a drop, so what was in flight is still here when the picture comes back —
                // and a carriage that was never finished is an arrangement nobody can press. See
                // ``abandonPictureTransit()``.
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
        // ``PictureIdentity/Change``, which is where a new source is told apart from the same stream
        // described again, and ``reactToPictureChange(from:to:)`` for what a change not already
        // covered by a hero transition does about it.
        //
        // Not `initial: true`: the first picture of a session has no previous zoom to invalidate.
        .onChange(of: model.picture) { previous, current in
            guard let previous, let current else { return }
            reactToPictureChange(from: previous, to: current)
        }
        // Turning the phone re-asks for the arrangement: the canvas takes the screen's own shape, so
        // a rotation is a different layout with a different identifier, and the Mac goes on capturing
        // the one it was asked for before, which the app then reads as "not showing a mosaic". See
        // ``SessionModel/refreshMosaicForViewport()``.
        //
        // Keyed on the orientation, which is the only thing that changes early: a rotation reaches
        // `screen.bounds` some two seconds after it starts, while the interface orientation flips at
        // the beginning of the movement, and `refreshMosaicForViewport` waits out the movement before
        // it reads anything.
        //
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
        .task(id: model.phase) {
            guard model.phase == .ready else { return }
            expandStatusBar()
        }
        .onChange(of: openPanel) { _, panel in
            if panel == nil { chromeFrames[.panel] = nil }
            if panel == .sources { askForSourcePictures() }
        }
        // **And again on a clock, for as long as the grid is up.** The pictures are taken on
        // demand, and until this existed the only thing that asked was the panel opening: left
        // open, the grid went on showing whatever the Mac looked like when it was first asked,
        // which is the wrong answer for a panel whose job is picking something that is there now.
        // Keyed on the panel, so closing it is what stops the loop.
        // One floating thing at a time: a panel and the keyboard each close the other.
        .onChange(of: openPanel) { _, panel in
            if panel != nil { model.showKeyboard = false }
        }
        .onChange(of: model.showKeyboard) { _, shown in
            if shown { withAnimation(Motion.settle) { openPanel = nil } }
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
        // A frame reaching the live layer is one half of what a transition is waiting on; the other
        // is its own animation settling, which calls the same function from inside
        // ``beginHeroTransition(to:target:carry:)``'s own timer. See ``endTransitionIfReady()``.
        .onChange(of: model.frameArrived) { _, _ in endTransitionIfReady() }
    }

    // MARK: - Keyboard input bar


    /// The modifiers, and the two keys with no other home while the keyboard is up.
    ///
    /// With the keyboard up, the dock and both rails are behind it, so nothing else on this screen can
    /// be pressed. Esc is the only way out of a Mac menu or a completion list and no iOS keyboard has
    /// one; Tab is how a Mac moves focus and completes. See ``ModifierBar``.
    /// The two keys that work on the field above, plus the ones that don't: escape, tab and the
    /// modifiers.
    ///
    /// **Leftmost and rightmost, and keys rather than glyphs.** Hide keyboard used to sit beside
    /// Return on the field's own row, which is the row that is narrowest exactly when a long
    /// sentence needs it widest. Demoted here, the two keys that work on the field bookend the row
    /// that has room for them: Hide keyboard is the end of the row the key that *leaves* belongs
    /// at, and Return — the software keyboard's own Return arrives as text, and keycode mode has no
    /// keycode for a newline, so a real one is only reachable from a key like this — is the end the
    /// key that *sends* belongs at. They wear the same cap, because nothing else in this row is
    /// pressed the same way. See ``compactCapButton(icon:action:)``.
    private var keyboardKeyRow: some View {
        HStack(spacing: 8) {
            compactCapButton(icon: "keyboard.chevron.compact.down", filled: true) { model.showKeyboard = false }
                .accessibilityLabel("Hide keyboard")
            ModifierBar()
            HStack(spacing: 6) {
                compactKeyButton(icon: "escape", keyCode: 53)
                    .accessibilityLabel("Escape")
                compactKeyButton(icon: "arrow.right.to.line", keyCode: 48)
                    .accessibilityLabel("Tab")
            }
            Spacer(minLength: 8)
            compactKeyButton(icon: "return", keyCode: 36) { model.pressReturn() }
                .accessibilityLabel("Enter")
        }
    }

    var keyboardInputBar: some View {
        VStack(spacing: 8) {
            // The field at the top, furthest from the thumb: it is read rather than pressed. Alone
            // on its row now, so it gets the row's full width rather than sharing it with the two
            // keys in ``keyboardKeyRow``.
            keyboardInputRow
            keyboardKeyRow
            // Nearest the keyboard, because it is the row the thumb reaches for most. The arrows move
            // the Mac's insertion point, which is the only way to reach the middle of a sentence that
            // lives on the other machine. See ``arrowStrip(withReturn:)``.
            arrowStrip(withReturn: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassSurface(in: RoundedRectangle(cornerRadius: ChromeMetrics.cornerRadius, style: .continuous))
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.top, ChromeMetrics.edgeInset)
    }

    /// The field, and what it is holding. The keys that work on it live in ``keyboardKeyRow``,
    /// the row below, so this row is the field's alone.
    private var keyboardInputRow: some View {
        // **The field itself, and it is a real one.** It holds the sentence, so iOS gives it a caret
        // that can be moved and reports every edit as a range plus a replacement, which is what
        // makes correcting the middle of a line work.
        //
        // No height of its own, deliberately: the wrapper answers with the height the sentence
        // needs, so the field grows a line at a time and this bar rises with it.
        KeyboardTypingCapture(
            model: model,
            isFocused: Binding(
                get: { model.showKeyboard },
                set: { model.showKeyboard = $0 }
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Darker than the glass it sits on: a field reads as recessed, and white text wants a
        // darker ground. The hairline is what keeps it a field over a bright desktop.
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
