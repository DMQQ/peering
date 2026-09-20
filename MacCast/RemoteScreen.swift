import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// The pointer's radius.
///
/// A file-level constant because three numbers have to agree: the circle's size, the horizontal
/// offset that centres it on the rail above it, and the centring of the key stacked on top of it.
let joystickRadius: CGFloat = 50

/// The remote desktop itself: picture, pointer, keyboard, and the controls for all three.
struct RemoteScreen: View {
    @Environment(SessionModel.self) var model

    /// Persisted because observe mode's no-input promise must survive a relaunch.
    @AppStorage(PreferenceKeys.interactionMode) var interactionMode: InteractionMode = .control

    /// Whether the picture is scaled up to reach the screen's edges.
    ///
    /// Persisted because it is a property of the *source*, not of the moment: a window captured
    /// on its own is usually a different shape from the screen, and someone who has just filled
    /// it will want the next one filled too.
    @AppStorage(PreferenceKeys.scalesToFill) var scalesToFill = false

    @State var zoom: CGFloat = 1
    @State var pan: CGSize = .zero
    @State var canvasSize: CGSize = .zero
    /// The position most recently commanded by this phone. Drawing it immediately keeps the
    /// pointer responsive even while the next video frame is still crossing the network.
    @State var remoteCursor = NormalizedPoint(x: 0.5, y: 0.5)
    /// Whether picking something from a floating panel puts the panel away.
    ///
    /// Persisted, because it is a working style rather than a moment: someone moving between a
    /// Mac's desktops wants the panel out of the way after each one, and someone picking their way
    /// through several sources in a row wants it to stay put.
    @AppStorage(PreferenceKeys.hidesPanelAfterSelect) var hidesPanelAfterSelect = true

    /// Whether the turn-your-phone card is on screen right now, and the timer that takes it away
    /// again. See ``presentLandscapeHint()``.
    ///
    /// This is the card's own state, and it is meant to die with the view: `ContentView` swaps
    /// this whole view out whenever the phase leaves the remote screens, so it is built fresh at
    /// the start of every session. Whether the card has *ever* been shown is a different question,
    /// with a different lifetime, and it is answered by ``hasSeenLandscapeHint`` below.
    @State var showsLandscapeHint = false
    @State var landscapeHintTask: Task<Void, Never>?

    /// Whether the turn-your-phone card has been shown, ever.
    ///
    /// Persisted, because "once" has to mean once for the install rather than once for the
    /// session, and nothing in this view outlives a session. Written in exactly one place,
    /// ``presentLandscapeHint()``, at the moment the card goes up.
    @AppStorage(PreferenceKeys.hasSeenLandscapeHint) var hasSeenLandscapeHint = false

    /// Set when iOS refused a rotation, which means Rotation Lock is on. Lasts as long as the
    /// session does, because the condition it describes does too.
    ///
    /// This variant is deliberately not gated by ``hasSeenLandscapeHint``, and it does not need to
    /// be. It is a reply to something the user just did, not an unsolicited hint; it can only be
    /// set by pressing the Rotate button, and that button only ever exists on a card that is
    /// already on screen. It is also the one thing in the app that can explain why the phone will
    /// not turn: an app cannot read Rotation Lock, so a refusal is the whole of the evidence, and
    /// whoever pressed Rotate is exactly the person who needs to hear it. Gating it on the
    /// once-only flag would take that answer away at the moment it became useful, leaving a user
    /// who asked for help with a card that vanishes instead of replying.
    @State var rotationRefused = false

    @State var openPanel: Panel?
    @State var statusBarExpanded = true
    /// Whether the portrait dock has opened onto the controls that did not earn a permanent
    /// place in it. Portrait's alone: the landscape rails have the height to show them all.
    @State var dockExpanded = false
    /// Which sheet of the dock is showing, by ``DockSheet/id``.
    ///
    /// Optional because that is what `scrollPosition(id:)` binds to: a pager that has not settled
    /// reports nothing, and a plainer binding would have to name a sheet it has not drawn. Nothing
    /// until it is swiped means the first sheet, which is where the pager already sits.
    @State var dockPage: String?
    /// The press counts the dock's ranking is read from, taken once when the screen is built.
    ///
    /// A snapshot rather than the store itself, and deliberately: the store is written to on every
    /// press, so reading it live would reorder the dock the instant a button was used and move
    /// that button out from under the finger that pressed it.
    @State var dockUsage: [String: Int] = DockUsage.counts()
    /// The pending auto-collapse, so expanding by hand can cancel the one already in flight.
    @State var statusBarCollapseTask: Task<Void, Never>?
    /// `⌘Q` sits in the always-available landscape actions. Unlike copy or paste it can discard
    /// unsaved work, so the permanent button asks once before sending the chord.
    @State var confirmsQuitApplication = false
    @State var showsTerminals = false

    /// What the joystick is showing about its own speed, for the second or so after it changes.
    @State var speedBadge: String?
    @State var speedBadgeTask: Task<Void, Never>?

    /// Where the window's own controls are, in the canvas's coordinates.
    ///
    /// The gesture surface has to be told: it is a UIKit view under SwiftUI's drawing, so a
    /// touch aimed at a button still reaches it, and a thumb that slides while pressing starts a
    /// drag on the Mac underneath — moving its pointer to wherever the finger happened to be.
    @State var chromeFrames: [ChromeRegion: CGRect] = [:]

    let minimumZoom: CGFloat = 0.5
    let maximumZoom: CGFloat = 8

    /// The one sliding panel.
    ///
    /// An enum rather than a boolean per panel, so "only one at a time" is true by construction.
    /// Two booleans could both be set, and the screen then had no rule about which of them won —
    /// which is how the two panels ended up overlapping in the first place.
    enum Panel {
        case shortcuts
        case desktops
        case sources
        case settings
    }

    /// Shows the turn-your-phone card to a session that came up in portrait, once in the life of
    /// the install.
    ///
    /// Portrait is not a failure, the dock and the joystick are built for it, but a Mac's screen is
    /// wide and side-on is where the picture gets the whole display. Most people work that out on
    /// their own within a few seconds; the card spends three of them saying so and then gets out
    /// of the way, which is why it is timed. That is also why it is not a reminder: it has said its
    /// one sentence, and a user who has read it and stayed upright has answered it. Coming back on
    /// the next session, and the one after that, is the annoyance this flag exists to end.
    ///
    /// The flag is written before the card is drawn, never when it goes away. It leaves by the
    /// phone being turned and by the timer running out far more often than by the tap, and neither
    /// of those runs a dismissal: a flag written only by the tap would bring the card back for
    /// almost everyone who did as it asked.
    func presentLandscapeHint() {
        // The landscape half of this guard is load-bearing for the flag. Nothing is marked when a
        // session comes up sideways, because the card was never on screen then, and a phone whose
        // first sessions are all landscape has had no hint to remember. The one it is owed is
        // still owed, and it is drawn the first time a session comes up in portrait.
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
    /// An app cannot read Rotation Lock. It can only ask, and the ask either happens or comes back
    /// as an error — so the error handler is the only way to tell a locked phone from a working
    /// one, and it is what turns this card into the instructions for unlocking it.
    ///
    /// The card stops fading while the request is out. A button that dismisses the thing it sits
    /// on halfway through being pressed is worse than no button at all.
    func rotateToLandscape() {
        landscapeHintTask?.cancel()
        landscapeHintTask = nil

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in
            // The handler is not guaranteed to be on the main actor and it writes view state, so
            // it comes back to it first.
            Task { @MainActor in
                withAnimation(Motion.settle) { rotationRefused = true }
            }
        }
    }

    /// Whether the phone is held sideways.
    ///
    /// Asked of the window rather than of the geometry the chrome is laid out in, and a bug lives
    /// in that difference. Two things inset that geometry from the bottom: the software keyboard,
    /// and the input bar added above it. On a phone held upright with the keyboard up, what was
    /// left was shorter than it was wide — so `width > height`, which is the test that decides
    /// *which* set of controls to draw, answered *landscape*, and the rails came down the edges of
    /// a portrait screen behind a keyboard and went away again when it was dismissed.
    ///
    /// The geometry cannot be asked instead: a `safeAreaInset` shrinks its content by design, and
    /// it has to, because the bar belongs above the keyboard. Which is why this one question is
    /// the one thing asked somewhere the keyboard cannot reach. The chrome is still *laid out* in
    /// the geometry, because it does have to stay clear of the keyboard.
    var deviceIsLandscape: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .interfaceOrientation
            .isLandscape ?? false
    }

    var body: some View {
        // `Environment` gives the object but no projected value, so a local `@Bindable` is
        // what turns `model.showKeyboard` into something the keyboard view can bind to.
        @Bindable var model = model
        return GeometryReader { proxy in
            let isLandscape = deviceIsLandscape
            ZStack {
                // Black here, where every other screen in the app uses the near-black backdrop
                // — and the difference is the picture. The video is letterboxed on any screen
                // that is not the Mac's own shape, and those bars sit directly against whatever
                // the Mac itself is showing in black: its desktop's letterbox, a dark editor, a
                // terminal. At 0.04 the join is a visible edge around the picture, which reads
                // as the picture being inset in a panel rather than as being the screen. At
                // zero the bars and the video's own black are the same black and the only thing
                // on screen is the Mac.
                Color.black.ignoresSafeArea()

                video
                clientCursor
                gestures
                sessionChrome(isLandscape: isLandscape, available: proxy.size)

                if case .confirming(let code) = model.phase {
                    PairingPrompt(code: code, hostName: model.hostName ?? "this Mac")
                }

                if model.phase == .connecting || model.phase == .handshaking {
                    ProgressOverlay(
                        title: model.phase == .connecting ? "Connecting…" : "Securing the connection…",
                        detail: model.hostName
                    )
                }

                // Hidden the moment the phone is actually turned, which is the whole of what it
                // asks for. The timer is still running underneath and will find it already gone.
                if showsLandscapeHint, !isLandscape {
                    LandscapeHint(
                        rotationRefused: rotationRefused,
                        onRotate: rotateToLandscape,
                        onDismiss: dismissLandscapeHint
                    )
                    .transition(.opacity)
                }
            }
        }
        // The keyboard must not resize the picture. A remote desktop whose view shrinks every
        // time the system keyboard appears would move every control the user is aiming at.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.showKeyboard {
                keyboardInputBar
            }
        }
        .background {
            KeyboardCapture(model: model, isFocused: $model.showKeyboard)
                .frame(width: 0, height: 0)
        }
        .sheet(isPresented: $showsTerminals) {
            TerminalPanel()
                .presentationDetents([.large])
                // The locks inside this sheet need a presenter inside this sheet: the deck's
                // macro editor, the quick commands, and both directions of the file browser are
                // gated, and every one of them is drawn on top of the terminal. A paywall asked
                // for from here and presented from the root is a tap that does nothing.
                .presentsPaywall(model)
        }
        // Nothing here is a sheet any more. Both of these are panels now, so the whole session —
        // what to share, what the connection is doing, the keys — lives in one visual language on
        // one layer, rather than three of them arriving from the bottom of the screen.
        // A hidden panel reports nothing, so its last frame would go on blocking touches in a
        // region that no longer has anything in it.
        // Keyed to the phase rather than to appearing, because a session does not arrive ready:
        // the screen is up during `.confirming` and the picture only starts at `.ready`, which is
        // the moment worth interrupting.
        .onChange(of: model.phase, initial: true) { _, phase in
            guard phase == .ready else { return }
            presentLandscapeHint()
        }
        .onChange(of: interactionMode, initial: true) { _, mode in
            model.setObserveOnly(mode == .observe)
        }
        // A zoom and a pan are chosen for one picture, and they mean nothing against another: a
        // magnification picked over a 1512×982 display leaves a 580×384 window cropped and
        // panned to a corner of a rectangle that is no longer there. The picture becomes a
        // different one in exactly one place, and the model watches for it there. See
        // ``PictureIdentity/Change``, which is where a new source is told apart from the same
        // stream described again. What to do about each is this view's business, because the
        // zoom and the pan are this view's state.
        //
        // Not `initial: true`, and that matters: the first picture of a session has no previous
        // zoom to invalidate, and the state it would be comparing against was built at its
        // default anyway.
        .onChange(of: model.picture) { previous, current in
            guard let previous, let current else { return }
            switch previous.change(to: current) {
            case .unchanged:
                break
            case .resized:
                // The magnification is kept. It is a multiple of the fit, so it still says what
                // it said before the window grew. The offset is not: it is measured in points of
                // a canvas whose picture has just changed shape, and left alone it can sit
                // outside the range the new picture allows. At rest there is no range at all,
                // so nothing the user can drag would bring it back.
                pan = clampedPan(pan)
            case .replaced:
                resetPicture()
            }
        }
        .onChange(of: openPanel) { _, panel in
            if panel == nil { chromeFrames[.panel] = nil }

            // The desktop pictures are the one thing here that is stale by design — they are
            // photographs, not a stream, and the host re-takes them on a schedule of its own.
            // Opening the panel is the moment they are about to be looked at, so it is the
            // moment to ask. The answer does not come back through this call: the host pushes
            // a catalogue when a picture lands, the same way it does for any other change.
            if panel == .desktops { model.send(.refreshSpacePreviews) }
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
    }

    // MARK: - Keyboard input bar

    var keyboardInputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text(model.typedPreview.isEmpty ? "Typing…" : model.typedPreview)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(model.typedPreview.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.showKeyboard = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassSurface(in: RoundedRectangle(cornerRadius: ChromeMetrics.cornerRadius, style: .continuous))
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.top, ChromeMetrics.edgeInset)
    }

}
