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
    /// The pixel size the current ``zoom`` factor was computed against.
    ///
    /// **Prevents a one-frame scale jump when the picture changes mid-animation.** ``effectiveZoom``
    /// multiplies ``zoom`` by a base scale derived from the picture's pixel size. When a new
    /// picture arrives, SwiftUI re-renders the view with the new ``model.capturePixelSize`` before
    /// ``onChange(of:)`` has a chance to correct ``zoom`` to match. The result for that one frame
    /// is ``new_base × old_zoom``, which is the wrong drawn scale and reads as a flicker.
    ///
    /// Keeping the pixel size as ``@State`` breaks the dependency: the base scale stays at the
    /// value it had when the animation started (the departing picture's size), so the frame before
    /// ``onChange`` fires is ``old_base × old_zoom`` — continuous with every frame before it. The
    /// ``onChange`` handler then sets both ``lockedPixelSize`` and ``zoom`` together, and the
    /// subsequent render uses ``new_base × placed_zoom``, which is the same drawn scale by
    /// construction. No jump, no flicker.
    ///
    /// Only consulted when a ``pictureGlide`` is in flight. At rest, ``pictureBaseScale`` reads
    /// from the live model so Fill mode and rotation are always using the right scale.
    @State var lockedPixelSize: CGSize = .zero
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

    /// Whether this screen's first-run tips have been seen. See ``Tour``.
    @AppStorage(PreferenceKeys.hasSeenTourScreen) var hasSeenTourScreen = false

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

    /// The movement the picture is in the middle of, if it is in one.
    ///
    /// **Either direction of the same journey.** A tile opening scales the picture until that
    /// window is what fills the screen; the arrangement coming back shrinks it into the tile it
    /// will hold. One task, because they are exclusive — a second tap takes over from the first,
    /// and so does a gesture that moves the picture by hand — and because the state they write is
    /// the same two numbers. See ``RemoteScreen/glidePicture(to:)``.
    @State var pictureGlide: PictureGlide?

    /// The picture a movement was aimed at, kept until that picture arrives.
    ///
    /// **The one thing the geometry cannot work out for itself.** Every other arrival is decided
    /// by comparing rectangles — see ``RemoteScreen/pictureIsAtRest`` — and this case cannot be,
    /// because the zoom on the view belongs to the picture being left: the movement that opens a
    /// tile ends with the zoom at two or three times the fit, which draws the arrangement with the
    /// tapped window at the size it will have and draws that window's own stream at two or three
    /// times the size it should be. Which of the two it is is not in the number. It is in what the
    /// movement promised, and this is that promise kept until the picture answers it. See
    /// ``PictureAim`` for why both directions of the movement have one.
    @State var pictureAim: PictureAim?

    /// The picture `MosaicZoom.placing` has been solved for, or `nil` while the movement is still
    /// showing the one it is leaving.
    ///
    /// A config arrives a frame or two before its first picture does, so the model describes the
    /// incoming stream while the layer still holds the outgoing one. This is what tells those two
    /// apart. See ``RemoteScreen/carriedWindow``.
    @State var placedPictureID: String?

    /// A picture the Mac has answered with that is not on the layer yet.
    ///
    /// A config arrives a frame or two before its own picture does. Everything the arrival writes
    /// (the zoom, the pan, the base scale, which branch the movement's hole is measured from) is
    /// expressed against the *arriving* picture, and writing it early draws the picture being
    /// replaced at the arriving one's scale: the whole mosaic flashing back at its fit in the
    /// middle of a zoom into a tile, and the tile flashing back to full size in the middle of a
    /// zoom out. So the work waits for ``VideoRenderer/onFirstFrame``, which is the only thing
    /// that knows the picture has actually changed. See ``settleArrival()``.
    @State var pendingArrival: PendingArrival?

    /// The wait that keeps a stream which never delivers its first frame from leaving the picture
    /// at the departing calibration for good. See ``settleArrival()``.
    @State var arrivalDeadline: Task<Void, Never>?

    /// The picture being replaced, and the scale and offset it was drawn at.
    ///
    /// The live layer is hidden for the render in which its contents change — the layer swaps them
    /// on a clock this app cannot see, so the only way to keep the wrong pair off the screen is to
    /// have it covered while it happens — and faded back in afterwards. See
    /// ``VideoLayerView/showsStill``.
    @State var swapping = false
    @State var stillZoom: CGFloat = 1
    @State var stillPan: CGSize = .zero

    /// Whether the outgoing picture is held under the arriving one across a swap.
    ///
    /// **Off, and the switch is here rather than deleted so the reasoning survives.** The idea is
    /// sound and the mechanism runs: the still layer keeps the departing stream's last frame at
    /// the departing transform while the live layer is hidden and given the new one, and the live
    /// layer fades back in over 180ms. Traced on the device, every arrival does exactly that.
    ///
    /// What it does not do is show the right picture. Tapping a tile in an arrangement puts
    /// something else on screen for about a fifth of a second. The owner's words: "in mosaic I
    /// see the google chat window in chrome, I click it and for a moment it shows me some other
    /// tab in chrome I was there a minute or 2 before, and then it flickers back". The frame the
    /// still is handed is ``VideoRenderer/outgoingFrame``, which is the last one this renderer gave
    /// the *live* layer, and the layer has no flush of its own: once it holds something it goes on
    /// holding it, so what it covers a swap with is not reliably the picture that was on screen.
    ///
    /// Turning it off removes both that and the flicker it was written to cure, which is the
    /// measurement that settles it. A version of this worth having needs the still to be given the
    /// frame the screen can actually see, which is a change to what the renderer keeps and not to
    /// when it fades.
    private static let crossFadeArrivals = false

    /// The two pictures an arrival is between. See ``pendingArrival``.
    struct PendingArrival {
        let previous: PictureIdentity
        let current: PictureIdentity
    }

    /// How far the veil over a turned arrangement has come up.
    ///
    /// **An arrangement that changes shape is a different picture**, and no amount of transforming
    /// makes the old one become the new one: the canvas a phone held up was showing is not the
    /// canvas it shows held sideways. What *can* be continuous is where the picture sits — the new
    /// canvas is drawn where the old one was and moves into its own shape, which is what a turn of
    /// the phone should look like — and this is the veil that covers the one moment that is not
    /// continuous, when the six windows rearrange themselves inside that frame. It comes up in the
    /// frame the canvas arrives and clears over the movement. See
    /// ``RemoteScreen/arrangementMorph(from:to:)``.
    @State var arrangementVeil: Double = 0

    /// The tile a long press is holding, and the slot the finger is over.
    ///
    /// **The whole of the state a reorder has**, and it is the screen's because the screen is the
    /// only side that knows both the arrangement and where the picture is on screen. The gesture
    /// surface reports a point; these are what that point means. See ``dropHeldTile()``.
    @State var heldTile: Int?
    @State var targetTile: Int?
    /// Where the finger holding it is, in the canvas's own coordinates.
    ///
    /// **Without this the tile never leaves its place**, which is what a long press to reorder is
    /// for: the frame of the tile in hand is drawn here rather than around its slot, so the thing
    /// being moved is under the thumb that picked it up. The picture under it cannot follow — the
    /// windows are one composited surface on the Mac — so what travels is the tile's outline and
    /// its name, and the accent marks the slot it would land in. See ``MosaicOverlay``.
    @State var heldPoint: CGPoint?

    let minimumZoom: CGFloat = 0.5
    let maximumZoom: CGFloat = 8

    /// The one sliding panel.
    ///
    /// An enum rather than a boolean per panel, so "only one at a time" is true by construction.
    /// Two booleans could both be set, and the screen then had no rule about which of them won —
    /// which is how the two panels ended up overlapping in the first place.
    enum Panel {
        case shortcuts
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

    /// What this screen owes, and what it waits for.
    ///
    /// **Three gates, all of them about a tour arriving before the screen is the screen.** The
    /// session has to be up, because the steps are drawn around a pill, a dock and a joystick that
    /// only exist once the picture does. The turn-your-phone card has to have gone, because it is
    /// the first thing a portrait session shows, it sits over the middle of the picture, and a tour
    /// running under a card is two things saying "look here" at once. And the flag has to say the
    /// tips are still owed, which is the one that survives the session.
    ///
    /// `showsLandscapeHint` is not a permanent condition and does not need to be: the card takes
    /// itself away after three seconds, and this is recomputed on every pass, so the tips begin the
    /// moment the screen is alone.
    private var dueScreenTours: [Tour] {
        guard model.phase == .ready, !showsLandscapeHint, !hasSeenTourScreen else { return [] }
        return [.screen]
    }

    /// Whether the phone is being held sideways — asked of the orientation it is *moving to*.
    ///
    /// **The only orientation signal a rotation gives at the start of it, and everything that
    /// depends on the orientation has to read it.** `interfaceOrientation` reports the orientation
    /// the interface is *in*, so on this device it changes when the movement has finished, along
    /// with the screen's own bounds — about two seconds after the user has turned the phone and
    /// while the rest of the app has already caught up. `effectiveGeometry` reports the orientation
    /// it is moving *to*, so it changes when the movement begins.
    ///
    /// The cost of reading it the late way is not one thing but three, arriving at three different
    /// moments: the arrangement is asked for late (so the tiles change late), the picture's margin
    /// appears late (so the mosaic is a quarter larger than it should be, and shrinks later, on a
    /// screen where everything else has settled), and the chrome swaps late (so the dock is there
    /// for a second and a half of a screen that is already sideways). Every one of those reads this
    /// property, and they now read the same thing at the same moment.
    ///
    /// Read from the window scene rather than the layout geometry, and that part is a correction
    /// with a bug behind it: a phone held upright with the keyboard up has less height than width,
    /// so `width > height` answered *landscape* and the rails came down the sides of a portrait
    /// screen behind a keyboard. The scene cannot lie about that in the same way.
    var deviceIsLandscape: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .effectiveGeometry
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
                mosaicOverlay
                clientCursor
                // Over the picture and its borders, under the chrome. The chrome is the app's own
                // and stays where it is; what is travelling is the Mac's picture, so what dims is
                // the Mac's picture. See ``arrangementVeil``.
                arrangementVeilView
                // Above the veil, because it is not a dim: while one window is being lifted out of
                // an arrangement, the rest of the picture is not there as far as this screen is
                // concerned. See ``carryingScrim``.
                carryingScrim
                gestures
                sessionChrome(isLandscape: isLandscape, available: proxy.size)

                if case .confirming(let code) = model.phase {
                    PairingPrompt(code: code, hostName: model.hostName ?? "this Mac")
                }

                // **The same decision the connecting card makes, and it has to be made in both
                // places.** This overlay used to be unreachable: the remote screen was unmounted
                // for the whole of a connection, so a scrim saying "Connecting…" could never be
                // drawn over it. Keeping the screen mounted for a resume is what makes this line
                // live, and a black veil with a spinner over a picture that never left is the one
                // thing a resume must not show.
                //
                // Pairing is deliberately not covered. Six digits are a security check rather than
                // theatre, and a resumed session that somehow needs them has to be able to show
                // them. See ``PairingPrompt`` just above.
                if (model.phase == .connecting || model.phase == .handshaking),
                   !model.isResumingAfterDrop {
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
            // On the stack rather than on a layer of its own, and it has to be: the tips are drawn
            // around the pill, the dock and the joystick, so the thing they are read from has to be
            // an ancestor of all three. A `Color.clear` put on top of this stack would be over the
            // picture and behind nothing, and would see no frames at all.
            .firstRunTours(dueScreenTours) { $0.markSeen() }
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
                // Swipe to dismiss is off. The terminal is a running process: an accidental swipe
                // that closes the sheet does not close the shell, but it looks like it did, and
                // the user who swiped by mistake has to find their way back in through the dock.
                // Done is the one deliberate way out.
                .interactiveDismissDisabled()
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
                flickerTrace("arrival unchanged src=\(current.sourceID ?? "nil")")
                break
            case .resized:
                // The magnification is kept. It is a multiple of the fit, so it still says what
                // it said before the window grew. The offset is not: it is measured in points of
                // a canvas whose picture has just changed shape, and left alone it can sit
                // outside the range the new picture allows. At rest there is no range at all,
                // so nothing the user can drag would bring it back.
                pan = clampedPan(pan)
                // **A change of picture is a change of picture, whichever case it arrives as.**
                // This one is the same window re-described at another resolution, which is the
                // reduced-quality stream on the control channel giving way to the full-quality one
                // on the direct channel — a swap the user watches even though the source never
                // changed. It used to arrive without a cross-fade for exactly that reason, and it
                // is the flicker a second after a tile finishes opening. See ``showsStill``.
                stillZoom = effectiveZoom
                stillPan = pan
                swapping = Self.crossFadeArrivals && model.renderer.hasStillPicture
                flickerTrace("""
                    arrival resized src=\(current.sourceID ?? "nil") \
                    was=\(previous.pixelSize.width)x\(previous.pixelSize.height) \
                    now=\(current.pixelSize.width)x\(current.pixelSize.height) \
                    still=\(swapping) zoom=\(Double(effectiveZoom))
                    """)
            case .replaced:
                flickerTrace("""
                    arrival replaced from=\(previous.sourceID ?? "nil") \
                    to=\(current.sourceID ?? "nil") \
                    \(current.pixelSize.width)x\(current.pixelSize.height) \
                    aim=\(pictureAim?.sourceID ?? "nil") hasStill=\(model.renderer.hasStillPicture)
                    """)
                // **Held until the picture the config describes is on the layer.** The work below
                // is all expressed against the arriving picture, and the layer is still showing
                // the one it replaced. See ``pendingArrival`` and ``settleArrival()``.
                pendingArrival = PendingArrival(
                    previous: pendingArrival?.previous ?? previous,
                    current: current
                )
                arrivalDeadline?.cancel()
                arrivalDeadline = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    settleArrival(force: true)
                }
                // The frame may already be on the layer, in which case there is nothing to wait
                // for and waiting would leave the picture at the departing calibration.
                settleArrival()
            }
        }
        // **Turning the phone re-asks for the arrangement.** The canvas takes the screen's own
        // shape, so a rotation is a different layout with a different identifier, and the Mac goes
        // on capturing the one it was asked for before — which the app then reads as "not showing
        // a mosaic", losing the tile borders and the picture's name on a turned phone. See
        // ``SessionModel/refreshMosaicForViewport()``.
        //
        // **Keyed on the orientation, which is the only thing that changes early.** The screen's
        // own bounds are what the canvas is built from, and they were what this watched until the
        // timing was measured: a rotation reaches `screen.bounds` some two seconds after it starts,
        // so an arrangement asked for on that signal arrived long after the phone had finished
        // turning. The interface orientation flips at the beginning of the movement, which is when
        // the user has decided, and `refreshMosaicForViewport` waits out the movement before it
        // does anything with it — so the bounds it reads are the settled ones either way.
        //
        // The canvas is deliberately not what is watched. It is the result of the arrangement and
        // the screen together, so it also changes when the user adds a window — which is an ask
        // they have just made themselves, and a second one sent from here would rebuild the
        // arrangement that is already being built.
        .onChange(of: shownMosaicLayout != nil) { _, visible in
            flickerTrace("overlay visible=\(visible) carrying=\(pictureAim?.carriesOutOfArrangement == true) glide=\(pictureGlide != nil) showingMosaic=\(model.isShowingMosaic)")
        }
        .onChange(of: deviceIsLandscape) { _, _ in
            model.refreshMosaicForViewport()
        }
        .onChange(of: openPanel) { _, panel in
            if panel == nil { chromeFrames[.panel] = nil }

            if panel == .sources {
                // The host never photographs these on its own, so without this the grid shows
                // nothing but outlines. Guarded on what the Mac said it can take: the request is a
                // command an older one cannot decode. See ``SourceThumbnailSupport``.
                if model.hostSupportsSourceThumbnails {
                    model.send(.refreshSourceThumbnails)
                }

                // Desktop pictures are photographs rather than a stream and are re-taken on the
                // host's own schedule, so opening the panel is the moment to ask for fresh ones.
                // Guarded on the grid's own predicate rather than on a version: this command
                // arrived with a protocol bump, so the handshake already guarantees the Mac can
                // decode it, and what is left to decide is whether there is anything to refresh.
                if panel == .sources,
                   let info = model.catalog?.spaceInfo,
                   SourcesPanel.showsDesktops(info) {
                    model.send(.refreshSpacePreviews)
                }
            }
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
        // The other half of the hold on an arrival: the frame landing is the picture changing.
        .onChange(of: model.frameArrived) { _, _ in settleArrival() }
        // **Back out of the hold, one display frame after going into it.** That render has
        // happened, so the live layer has been handed the arriving frame; the pause is for the
        // layer to put it on the screen, because a fade that started first would be blending into
        // a picture that had not changed yet and the swap would land in the middle of it.
        .onChange(of: swapping) { _, swap in
            guard swap else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                swapping = false
            }
        }
    }

    /// Does what an arrival does, now that its picture is the one on screen.
    ///
    /// The whole of what the zoom and the pan have to answer to. Held back from the config that
    /// announced it because a config is not a picture (see ``pendingArrival``), and run either
    /// when the frame lands or when the deadline above gives up on it ever landing.
    func settleArrival(force: Bool = false) {
        guard let pending = pendingArrival else { return }
        flickerTrace("""
            settleArrival force=\(force) ready=\(model.isReadyToPlace(of: pending.current.pixelSize)) \
            to=\(pending.current.pixelSize.width)x\(pending.current.pixelSize.height)
            """)
        // Asked of the renderer rather than inferred from which of the two arrived first: the
        // frame's own hop to the main actor can beat the config's, and either can be late.
        // `force` is the deadline, which is the one caller that has decided the wait is over.
        guard force || model.isReadyToPlace(of: pending.current.pixelSize) else { return }
        pendingArrival = nil
        arrivalDeadline?.cancel()
        arrivalDeadline = nil
        let previous = pending.previous
        let current = pending.current

        // **The picture on screen at this instant, and the scale it is drawn at.** Whatever the
        // arrival does below, that picture has to go on being shown while the live layer takes the
        // new frame — the still holds it, at the scale it had here rather than at the one the
        // arrival is about to write. See ``VideoLayerView/showsStill``.
        //
        // Set before the work rather than inside either branch, because the branches disagree
        // about the transform and agree about this: both of them replace the picture on screen.
        stillZoom = effectiveZoom
        stillPan = pan
        // Only if there is something to cover it with: an empty still under a hidden live layer is
        // a black frame, which is worse than the cut this replaces.
        swapping = Self.crossFadeArrivals && model.renderer.hasStillPicture

        // **A turn of the phone is a movement, not a cut.** An arrangement that arrives
        // where another arrangement was is drawn where that one was and moves into its own
        // shape, with its borders travelling with it; anything else — a window opened, a
        // window behind a mosaic — is the reset every source switch has always had. See
        // ``arrangementMorph(from:to:)``.
        if let target = arrangementMorph(from: previous, to: current) {
            zoom = target.zoom
            pan = target.pan
            // Up in the frame the new canvas arrives — the same frame its first pixels do,
            // because the frame gate holds them until this update has been laid out — and
            // gone by the time the movement has landed.
            arrangementVeil = 1
            // A turn of the run loop between the two, because two writes to one value in
            // one update are one write: the veil would be animated to nothing from nothing
            // and there would be no dim at all.
            Task { @MainActor in
                withAnimation(Motion.settle) { arrangementVeil = 0 }
            }
        }
        // **The picture the movement was carrying is put where the movement has it**, and
        // then the movement finishes on the new picture.
        //
        // This is the whole of what made the zoom look broken. The zoom on the view
        // belongs to the picture being *left*: the movement that opens a tile ends with it
        // at two or three times the fit, because that is what draws the tapped window at
        // the size it will have inside the *canvas*. Read against the window's own stream,
        // the same number draws that window at two or three times too big, so a switch
        // that kept the number showed the window huge and then shrank it back to the fit.
        // Correcting it by gliding — which is what this did — is that shrink, animated:
        // "it zooms in, and then out to fit the window on screen".
        //
        // So the state is not kept and not corrected: it is *solved*, for the rectangle
        // the movement already has the window in. See
        // ``MacCastKit/MosaicZoom/placing(pixelSize:anchor:at:bounds:scale:)``. The picture
        // changes and nothing on screen moves, whatever the timing — which matters,
        // because the Mac usually builds the stream faster than the movement takes, and
        // the arrival therefore usually happens part-way through it.
        // **Kept when the picture that arrived is the one it was for, and dropped when it
        // is not.** Kept, because the hole the movement opened must outlive the arrival:
        // what is on screen changes a frame or two before the arriving stream's own
        // picture is, and a hole that closed at the arrival would put the arrangement's
        // last frame back on screen for exactly one blink. Dropped for anything else — a
        // display picked out of a panel, an arrangement coming back — because the promise
        // describes a window of *that* arrangement and means nothing about another picture.
        let aim = pictureAim
        flickerTrace("picture replaced previous=\(previous.sourceID ?? "nil") current=\(current.sourceID ?? "nil") aim=\(aim?.sourceID ?? "nil") glide=\(pictureGlide != nil) zoom=\(Double(zoom))")
        if aim?.sourceID != current.sourceID { pictureAim = nil }

        let carried = aim.flatMap { aim -> CGRect? in
            guard aim.sourceID == current.sourceID else { return nil }
            // **The departing picture's own effective zoom, not the arriving one's.**
            // `effectiveZoom` already reflects the new picture's base scale, and in Fill
            // mode the canvas and a window have very different base scales. The canvas is
            // what the movement was running against, so the rect has to be measured at
            // the canvas's base scale — which is what `aim.departedSize` is the size of.
            let departedEffectiveZoom = pictureScale.base(pixelSize: aim.departedSize, in: canvasSize) * zoom
            return CanvasGeometry.rect(
                normalized: aim.departedAnchor,
                bounds: canvasSize,
                pixelSize: aim.departedSize,
                zoom: departedEffectiveZoom,
                pan: pan
            )
        }
        let placed = carried.flatMap { rect in
            MosaicZoom.placing(
                pixelSize: current.pixelSize,
                anchor: aim?.anchor ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                at: rect,
                bounds: canvasSize,
                scale: pictureScale
            )
        }

        if let placed {
            lockedPixelSize = current.pixelSize
            zoom = placed.zoom
            placedPictureID = current.sourceID
            pan = placed.pan
            // **The rest of the journey, on the curve that was already running.** The
            // spring is evaluated from the progress it has reached rather than from the
            // beginning, so a picture crossing the screen keeps its speed: see
            // ``PictureGlide/reaim(to:progress:)``. With no movement left there is nothing
            // to carry on and nothing to write: the zoom and the pan above are where a
            // finished movement ended, which is where the picture belongs.
            if var glide = pictureGlide {
                let elapsed = (ContinuousClock().now - glide.startedAt) / .seconds(1)
                let progress = Motion.settleProgress(at: elapsed, response: Motion.pictureResponse)
                flickerTrace("picture placed progress=\(progress) placedZoom=\(Double(placed.zoom))")
                if progress < 0.995 {
                    glide.reaim(
                        to: (zoom: 1, pan: .zero),
                        through: placed,
                        progress: progress
                    )
                    pictureGlide = glide
                } else {
                    // The spring is just past its endpoint, but the renderer can still
                    // be showing the mosaic until the first window frame is displayed.
                    // Re-aim at the endpoint using the last solvable point on the curve;
                    // this keeps the in-flight animation and the window aim alive through
                    // that renderer hand-off instead of snapping or continuing toward the
                    // mosaic's old zoom target.
                    flickerTrace("late arrival reaims glide from placed window")
                    glide.reaim(
                        to: (zoom: 1, pan: .zero),
                        through: placed,
                        progress: 0.994
                    )
                    pictureGlide = glide
                }
            }
        } else {
            flickerTrace("picture had no carried placement aimMatched=\(aim?.sourceID == current.sourceID)")
            // Nothing the movement was carrying, so nothing to keep still: a source picked
            // out of a panel, a rotation, a window resized since the catalogue was read.
            // One already at rest is left alone; one that is not is moved to it.
            cancelPictureGlide()
            if pictureIsAtRest {
                resetPicture()
            } else {
                glidePicture(to: (zoom: 1, pan: .zero))
            }
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
