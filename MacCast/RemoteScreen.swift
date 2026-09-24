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
struct RemoteScreen: View {
    @Environment(SessionModel.self) var model

    /// Persisted because observe mode's no-input promise must survive a relaunch.
    @AppStorage(PreferenceKeys.interactionMode) var interactionMode: InteractionMode = .control

    /// Whether the picture is scaled up to reach the screen's edges.
    ///
    /// Persisted: it is a property of the *source*, not of the moment.
    @AppStorage(PreferenceKeys.scalesToFill) var scalesToFill = false

    @State var zoom: CGFloat = 1
    @State var pan: CGSize = .zero
    /// The pixel size the current ``zoom`` factor was computed against.
    ///
    /// Consulted while a ``pictureGlide`` is in flight: it holds the base scale on the departing
    /// picture's size until ``onChange(of:)`` writes this and ``zoom`` together, which is what keeps
    /// the frame before it continuous instead of a one-frame scale jump.
    @State var lockedPixelSize: CGSize = .zero
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
    /// Which sheet of the dock is showing, by ``DockSheet/id``.
    ///
    /// Optional because that is what `scrollPosition(id:)` binds to: a pager that has not settled
    /// reports nothing, and `nil` means the first sheet, which is where the pager already sits.
    @State var dockPage: String?
    /// The press counts the dock's ranking is read from, taken once when the screen is built.
    ///
    /// A snapshot rather than the store itself: read live, a press would reorder the dock and move
    /// that button out from under the finger that pressed it.
    @State var dockUsage: [String: Int] = DockUsage.counts()
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

    /// The movement the picture is in the middle of, if it is in one.
    ///
    /// Either direction of the same journey: opening a tile and the arrangement coming back write
    /// the same two numbers, and they are mutually exclusive. See
    /// ``RemoteScreen/glidePicture(to:)``.
    @State var pictureGlide: PictureGlide?

    /// The picture a movement was aimed at, kept until that picture arrives.
    ///
    /// The one arrival the geometry cannot decide for itself: the zoom on the view belongs to the
    /// picture being left, so whether it should be kept or solved is not in the number. See
    /// ``PictureAim``.
    @State var pictureAim: PictureAim?

    /// The picture `MosaicZoom.placing` has been solved for, or `nil` while the movement is still
    /// showing the one it is leaving.
    ///
    /// A config arrives a frame or two before its first picture does. See
    /// ``RemoteScreen/carriedWindow``.
    @State var placedPictureID: String?

    /// A picture the Mac has answered with that is not on the layer yet.
    ///
    /// Everything the arrival writes (the zoom, the pan, the base scale, which branch the movement's
    /// hole is measured from) is expressed against the *arriving* picture, so it waits for
    /// ``VideoRenderer/onFirstFrame``, which is the only thing that knows the picture has changed.
    /// Written early it draws the picture being replaced at the arriving one's scale. See
    /// ``settleArrival()``.
    @State var pendingArrival: PendingArrival?

    /// Bounds the wait, so a stream that never delivers a first frame cannot leave the picture at
    /// the departing calibration for good. See ``settleArrival()``.
    @State var arrivalDeadline: Task<Void, Never>?

    /// The picture being replaced, and the scale and offset it was drawn at.
    ///
    /// The live layer swaps its contents on a clock this app cannot see, so it is hidden for that
    /// render and faded back in afterwards. See ``VideoLayerView/showsStill``.
    @State var swapping = false
    @State var stillZoom: CGFloat = 1
    @State var stillPan: CGSize = .zero

    /// Whether the outgoing picture is held under the arriving one across a swap.
    ///
    /// Off. The still is handed ``VideoRenderer/outgoingFrame``, the last frame this renderer gave
    /// the *live* layer, and the layer has no flush of its own, so what covers a swap is not
    /// reliably the picture that was on screen. Off is also what removes the flicker.
    private static let crossFadeArrivals = false

    /// The two pictures an arrival is between. See ``pendingArrival``.
    struct PendingArrival {
        let previous: PictureIdentity
        let current: PictureIdentity
    }

    /// How far the veil over a turned arrangement has come up.
    ///
    /// An arrangement that changes shape is a different picture; what can be continuous is where it
    /// sits. This covers the one moment that is not, the windows rearranging themselves inside that
    /// frame. Comes up in the frame the canvas arrives and clears over the movement. See
    /// ``RemoteScreen/arrangementMorph(from:to:)``.
    @State var arrangementVeil: Double = 0

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

    /// When the arrangement the phone is asking for stopped being the one on screen, if it has.
    ///
    /// The clock behind ``mosaicBordersHeld``: a rebuild of an arrangement is the Mac tearing one
    /// canvas down and building another, and the borders are held back for it rather than drawn over
    /// the black. Stamped only for a change the Mac has to build again, so a reorder keeps its own
    /// feedback.
    @State var mosaicRebuildStartedAt: Date?

    let minimumZoom: CGFloat = 0.5
    let maximumZoom: CGFloat = 8

    /// The one sliding panel.
    ///
    /// An enum rather than a boolean per panel, so "only one at a time" is true by construction.
    enum Panel {
        case shortcuts
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

    /// Whether the phone is being held sideways — asked of the orientation it is *moving to*.
    ///
    /// The only orientation signal a rotation gives at the start of it, and everything that depends
    /// on the orientation reads it: `interfaceOrientation` changes when the movement has finished,
    /// about two seconds later, along with the screen's own bounds, while `effectiveGeometry`
    /// reports the orientation it is moving to and changes when the movement begins.
    ///
    /// Read from the window scene rather than the layout geometry: a phone held upright with the
    /// keyboard up has less height than width, so `width > height` answered *landscape*.
    var deviceIsLandscape: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .effectiveGeometry
            .interfaceOrientation
            .isLandscape ?? false
    }

    var body: some View {
        // `Environment` gives the object but no projected value, so a local `@Bindable` is what the
        // keyboard view binds to.
        @Bindable var model = model
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
                // stays where it is. See ``arrangementVeil``.
                arrangementVeilView
                // Above the veil, because it is not a dim. See ``carryingScrim``.
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
                // places: the screen stays mounted for a resume, and a black veil with a spinner
                // over a picture that never left is the one thing a resume must not show.
                //
                // Pairing is deliberately not covered: a resumed session that somehow needs the six
                // digits has to be able to show them. See ``PairingPrompt`` just above.
                if (model.phase == .connecting || model.phase == .handshaking),
                   !model.isResumingAfterDrop {
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
        }
        // The keyboard must not resize the picture: a shrinking view moves every control the user
        // is aiming at.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.showKeyboard {
                keyboardInputBar
            }
        }
        .background {
            // One keyboard, two views, and the mode is what decides which. Unicode mode goes
            // through a field because that is where iOS keeps autocorrection and prediction, and
            // keycode mode goes through the bare view because there is no text in it to correct:
            // the characters are translated into Mac keystrokes as they arrive. See
            // ``KeyboardTypingView``.
            switch model.keyboardMode {
            case .unicode:
                KeyboardTypingCapture(model: model, isFocused: $model.showKeyboard)
                    .frame(width: 0, height: 0)
            case .keycode:
                KeyboardCapture(model: model, isFocused: $model.showKeyboard)
                    .frame(width: 0, height: 0)
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
        .onChange(of: model.phase, initial: true) { _, phase in
            guard phase == .ready else { return }
            presentLandscapeHint()
        }
        .onChange(of: interactionMode, initial: true) { _, mode in
            model.setObserveOnly(mode == .observe)
        }
        // A zoom and a pan are chosen for one picture and mean nothing against another. The picture
        // becomes a different one in exactly one place, and the model watches for it there. See
        // ``PictureIdentity/Change``, which is where a new source is told apart from the same stream
        // described again.
        //
        // Not `initial: true`: the first picture of a session has no previous zoom to invalidate.
        .onChange(of: model.picture) { previous, current in
            guard let previous, let current else { return }
            switch previous.change(to: current) {
            case .unchanged:
                break
            case .resized:
                // The magnification is kept, because it is a multiple of the fit. The offset is
                // measured in points of a canvas whose picture has just changed shape, so left alone
                // it can sit outside the range the new picture allows.
                pan = clampedPan(pan)
                // A change of picture is a change of picture, whichever case it arrives as: this one
                // is the same window re-described at another resolution, the reduced-quality stream
                // giving way to the full-quality one, a swap the user watches even though the source
                // never changed. See ``showsStill``.
                stillZoom = effectiveZoom
                stillPan = pan
                swapping = Self.crossFadeArrivals && model.renderer.hasStillPicture
            case .replaced:
                // Held until the picture the config describes is on the layer: the work below is
                // expressed against the arriving picture, and the layer is still showing the one it
                // replaced. See ``pendingArrival`` and ``settleArrival()``.
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
                // The frame may already be on the layer, and waiting then would leave the picture at
                // the departing calibration.
                settleArrival()
            }
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
        .onChange(of: openPanel) { _, panel in
            if panel == nil { chromeFrames[.panel] = nil }
            if panel == .sources { askForSourcePictures() }
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
        // The other half of the hold on an arrival: the frame landing is the picture changing.
        .onChange(of: model.frameArrived) { _, _ in settleArrival() }
        // Back out of the hold one display frame after going into it: that render is what hands the
        // arriving frame to the layer, and the pause is for the layer to put it on the screen. A
        // fade started first would blend into a picture that had not changed yet.
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
    /// Held back from the config that announced it, because a config is not a picture (see
    /// ``pendingArrival``), and run when the frame lands or when the deadline gives up on it.
    func settleArrival(force: Bool = false) {
        guard let pending = pendingArrival else { return }
        // Asked of the renderer rather than inferred from which of the two arrived first: the frame's
        // hop to the main actor can beat the config's, and either can be late. `force` is the
        // deadline, the one caller that has decided the wait is over.
        //
        // On the layer, or ready with nothing left moving. The placement is the *arriving* picture's
        // transform, and writing it while the departing picture is still on the layer draws that
        // picture at the wrong scale; the two transforms describe the same rectangle exactly when the
        // movement has finished, which is the other moment this may run. See
        // ``RemoteScreen/pictureIsPlaced``.
        let settled = pictureGlide == nil && model.isReadyToPlace(of: pending.current.pixelSize)
        guard force
            || settled
            || model.hasPictureOnScreen(of: pending.current.pixelSize)
        else { return }
        pendingArrival = nil
        arrivalDeadline?.cancel()
        arrivalDeadline = nil
        let previous = pending.previous
        let current = pending.current

        // The picture on screen at this instant, at the scale it is drawn at here: the still holds
        // it while the live layer takes the new frame, at this scale rather than at the one the
        // arrival is about to write. Set before the branches, which disagree about the transform and
        // agree about this. See ``VideoLayerView/showsStill``.
        stillZoom = effectiveZoom
        stillPan = pan
        // Only if there is something to cover it with: an empty still under a hidden live layer is a
        // black frame, worse than the cut it replaces.
        swapping = Self.crossFadeArrivals && model.renderer.hasStillPicture

        // A turn of the phone is a movement, not a cut: an arrangement that arrives where another
        // was is drawn where that one was and moves into its own shape, with its borders travelling
        // with it, and is dimmed for the instant the windows rearrange themselves inside that
        // travelling frame. See ``arrangementMorph(from:to:)`` and ``arrangementVeil``.
        //
        // A window coming home is not dimmed: it slides into the slot it will occupy and the canvas
        // appears around it, which is a change of place, and dimming it would be a flash of black at
        // the moment the user is watching the picture.
        if let target = arrangementMorph(from: previous, to: current) {
            zoom = target.zoom
            pan = target.pan
            // Up in the frame the new canvas arrives, the same frame its first pixels do, because
            // the frame gate holds them until this update has been laid out, and gone by the time
            // the movement has landed.
            arrangementVeil = 1
            // A turn of the run loop between the two, because two writes to one value in one update
            // are one write: the veil would be animated to nothing from nothing.
            Task { @MainActor in
                withAnimation(Motion.settle) { arrangementVeil = 0 }
            }
        }
        // The picture the movement was carrying is put where the movement has it, and then the
        // movement finishes on the new picture.
        //
        // The zoom on the view belongs to the picture being *left*: read against the window's own
        // stream, the same number draws that window at two or three times too big. So the state is
        // not kept and not corrected, it is *solved*, for the rectangle the movement already has the
        // window in. See ``MacCastKit/MosaicZoom/placing(pixelSize:anchor:at:bounds:scale:)``.
        // **Kept when the picture that arrived is the one it was for, dropped otherwise.** The hole
        // the movement opened must outlive the arrival, or the arrangement's last frame comes back
        // on screen for a blink; but a promise about one arrangement's window means nothing about
        // another picture.
        let aim = pictureAim
        if aim?.sourceID != current.sourceID { pictureAim = nil }

        let carried = aim.flatMap { aim -> CGRect? in
            guard aim.sourceID == current.sourceID else { return nil }
            // The departing picture's own effective zoom, not the arriving one's: in Fill mode the
            // canvas and a window have very different base scales, and the canvas is what the movement
            // ran against. `aim.departedSize` is the size of that canvas.
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
            // The rest of the journey, on the curve that is already running: the spring is evaluated
            // from the progress it has reached rather than from the beginning, so a picture crossing
            // the screen keeps its speed. See ``PictureGlide/reaim(to:progress:)``.
            if var glide = pictureGlide {
                let elapsed = (ContinuousClock().now - glide.startedAt) / .seconds(1)
                let progress = Motion.settleProgress(at: elapsed, response: Motion.pictureResponse)
                if progress < 0.995 {
                    glide.reaim(
                        to: (zoom: 1, pan: .zero),
                        through: placed,
                        progress: progress
                    )
                    pictureGlide = glide
                } else {
                    // Just past the endpoint, but the renderer can still be showing the mosaic
                    // until the first window frame is displayed. Re-aiming at the last solvable
                    // point keeps the in-flight animation and the window aim alive through that
                    // hand-off instead of snapping.
                    glide.reaim(
                        to: (zoom: 1, pan: .zero),
                        through: placed,
                        progress: 0.994
                    )
                    pictureGlide = glide
                }
            }
        } else {
            // Nothing the movement was carrying, so nothing to keep still: a source picked out of a
            // panel, a rotation, a window resized since the catalogue was read. One already at rest
            // is left alone; one that is not is moved to it.
            cancelPictureGlide()
            // The picture has changed, whatever is about to be done with its framing: the base scale
            // is measured against the picture on screen, and from here that is this one. See
            // ``RemoteScreen/pictureBaseScale``.
            lockedPixelSize = model.capturePixelSize ?? .zero
            placedPictureID = current.sourceID
            if pictureIsAtRest {
                resetPicture()
            } else {
                glidePicture(to: (zoom: 1, pan: .zero))
            }
        }
    }

    // MARK: - Keyboard input bar

    /// The mark that says the line is still open and where the next character goes.
    ///
    /// **The bar is the only place a caret can be.** The Mac's own is in the Mac's own window, at
    /// whatever the Mac is holding; this one belongs to the sentence the bar is showing, and it is
    /// drawn the way ``TerminalStarting`` draws its own: a short bar of ink, on for most of the
    /// cycle and off for the rest, because an even square wave reads as a lamp flashing.
    ///
    /// Driven by a `TimelineView` rather than by a repeating animation: `repeatForever` is cancelled
    /// the moment this row is laid out again, and the row is laid out again every time the picture
    /// changes size, which leaves a caret that blinks until something happens and then never again.
    private struct TypingCaret: View {
        var body: some View {
            TimelineView(.periodic(from: .now, by: 0.12)) { context in
                let isOn = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.0) < 0.62
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(ColorPalette.ink)
                    .frame(width: 2, height: 14)
                    .opacity(isOn ? 1 : 0)
            }
            // Decoration for the eye only: the line it marks is what a reader needs, and it is
            // already in the label beside it.
            .accessibilityHidden(true)
        }
    }

    var keyboardInputBar: some View {
        HStack(spacing: 10) {
            // **Leftmost, and a key rather than a glyph.** It used to be a bare chevron on the far
            // side of Return, which is the end of the row the key that *sends* lives at and not the
            // end the key that *leaves* belongs at; drawn as a glyph it read as a caption for the
            // field. It wears the same cap as the Return beside it, because they are this row's two
            // keys and nothing else in it is pressed. See ``compactCapButton(icon:action:)``.
            compactCapButton(icon: "keyboard.chevron.compact.down") { model.showKeyboard = false }
                .accessibilityLabel("Hide keyboard")

            // What the bar is for, said in the words that change: the leading keyboard glyph that
            // used to stand here went with the move above, and this line was always the state it
            // was drawing.
            //
            // **And the caret after it, which is the other half of what a text field is.** Every
            // other field on the phone has one and this bar did not: it showed the sentence the Mac
            // was being sent with nothing at the end of it to say that more was coming, or where.
            HStack(spacing: 1) {
                Text(model.typedPreview.isEmpty ? "Typing…" : model.typedPreview)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(model.typedPreview.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                TypingCaret()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The software keyboard's Return arrives as text, and keycode mode has no keycode for a
            // newline, so a real Return is only reachable from a key like this one.
            compactKeyButton(icon: "return", keyCode: 36) { model.pressReturn() }
                .accessibilityLabel("Enter")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassSurface(in: RoundedRectangle(cornerRadius: ChromeMetrics.cornerRadius, style: .continuous))
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .padding(.top, ChromeMetrics.edgeInset)
    }

}
