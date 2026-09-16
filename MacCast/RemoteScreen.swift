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

    /// Persisted, because a user who works in drag & zoom on a phone should not have to say so
    /// again on every launch.
    @AppStorage("Peering.interactionMode") var interactionMode: InteractionMode = .control

    /// Whether the picture is scaled up to reach the screen's edges.
    ///
    /// Persisted because it is a property of the *source*, not of the moment: a window captured
    /// on its own is usually a different shape from the screen, and someone who has just filled
    /// it will want the next one filled too.
    @AppStorage("Peering.scalesToFill") var scalesToFill = false

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
    @AppStorage(PreferenceKey.hidesPanelAfterSelect) var hidesPanelAfterSelect = true

    /// The turn-your-phone card, and the timer that takes it away again — see
    /// ``presentLandscapeHint()``.
    ///
    /// No "has it been shown" flag is needed. `ContentView` swaps this whole view out whenever the
    /// phase leaves the remote screens, so the state below is built fresh at the start of every
    /// session and cannot survive into the next one.
    /// Set when the Move button armed the command key, so the end of the drag that wanted it
    /// knows to let go again.
    ///
    /// Deliberately not the button's selected state, which reads the latched modifiers
    /// themselves: command can be armed from the shortcuts panel too, and the button should
    /// light up for that without this claiming a release it did not cause.
    @State var moveArmed = false
    @State var showsLandscapeHint = false
    @State var landscapeHintTask: Task<Void, Never>?
    /// Set when iOS refused a rotation, which means Rotation Lock is on. Lasts as long as the
    /// session does, because the condition it describes does too.
    @State var rotationRefused = false

    @State var openPanel: Panel?
    @State var statusBarExpanded = true
    /// Whether the portrait dock has opened onto the controls that did not earn a permanent
    /// place in it. Portrait's alone — the landscape rails have the height to show them all.
    @State var dockExpanded = false
    /// The pending auto-collapse, so expanding by hand can cancel the one already in flight.
    @State var statusBarCollapseTask: Task<Void, Never>?
    /// `⌘Q` sits in the always-available landscape actions. Unlike copy or paste it can discard
    /// unsaved work, so the permanent button asks once before sending the chord.
    @State var confirmsQuitApplication = false
    @State var showsTerminals = false

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

    /// Shows the turn-your-phone card, once, to a session that came up in portrait.
    ///
    /// Portrait is not a failure — the dock and the joystick are built for it — but a Mac's
    /// screen is wide, and side-on is where the picture gets the whole display. Most people work
    /// that out on their own within a few seconds; the card spends three of them saying so and
    /// then gets out of the way, which is why it is timed rather than something to dismiss.
    func presentLandscapeHint() {
        guard !deviceIsLandscape, !showsLandscapeHint else { return }
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
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: ChromeMetrics.cornerRadius, style: .continuous)
        )
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.top, ChromeMetrics.edgeInset)
    }

}
