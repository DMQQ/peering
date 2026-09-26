import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// The root. Two screens, and which one is showing is a direct function of the session phase —
/// there is no separate "am I connected" flag that could disagree with the phase.
struct ContentView: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the first-run introduction has been seen.
    ///
    /// The second question this router asks, and deliberately a separate one from the first.
    /// `phase` answers "is there a session"; this answers "has this person been here before" —
    /// and the two are unrelated, which is why they are two branches rather than one condition
    /// with an `&&` in it.
    @AppStorage(PreferenceKeys.hasSeenWelcome) private var hasSeenWelcome = false

    private var isRemoteScreen: Bool {
        // **A Mac being put back keeps this screen, and most of the change follows from that.** A
        // drop leaves the phase at `.failed`, which used to unmount this whole subtree and hand
        // over to the picker: the picture left the screen, the picker ran its staggered entrance,
        // the connecting card went up over a session that was only changing networks, and every
        // piece of state in here (the zoom, the open panel, the dock) was thrown away and rebuilt.
        // None of that is a connection being made. It is one being restored, and the honest thing
        // to leave on screen is the frame the session left behind.
        //
        // Asked of the session rather than of the phase, because a first connection passes through
        // the same phases and should keep behaving exactly as it does: see
        // ``MacSession/isResumingAfterDrop``.
        //
        // **And a session the user has stepped away from is one this screen is not.** That is the
        // whole of the flag, and it is read first because it is the user's own last word: the cases
        // below are all about a session that is being watched. See
        // ``SessionModel/isSessionOnScreen``.
        //
        // **A resume with no session object behind it counts too.** A process killed in the
        // background comes back with nothing, dials the Mac it was last on, and passes through the
        // same phases a first connection does — so the same guard that keeps a drop on this screen
        // has to keep this one too, or the picker shows for as long as the dial takes. There is no
        // frame to leave up in that case, and the session screen's own header is what says what is
        // happening: see ``MacSession/isBeingPutBack``.
        guard model.isSessionOnScreen else { return false }
        if model.isBeingPutBack {
            // A launch putting back a Mac it has not reached yet stays off the Mac's screen until
            // it is connected, so a Mac that is not there leaves the user on Connect.
            if let session = model.activeSession, session.isComingBack, !session.hasBeenReady {
                return model.phase == .ready
            }
            return true
        }
        switch model.phase {
        case .ready, .confirming: return true
        default: return false
        }
    }

    /// How one screen hands over to another.
    ///
    /// Asymmetric, because the two are not equals: one is being left and the other arrived at.
    /// The outgoing screen recedes, shrinking away from the viewer, while the incoming one comes
    /// up through it slightly oversized and settles — which is the shape of moving *into*
    /// something rather than of one thing being swapped for another. Opacity and a small scale,
    /// deliberately nothing more: a slide would say the two screens sit side by side, and a blur
    /// would cost a frame of live video to buy nothing.
    private static let screenHandover = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 1.06, anchor: .center)),
        removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .center))
    )

    /// Whether the connecting card is up, and when the attempt started.
    ///
    /// Owned here rather than by the picker, and that is the whole of why it was never seen:
    /// the picker is *removed* the moment the session becomes ready, which is well inside the
    /// time the card needs to be legible — so a card drawn on it was built and destroyed with
    /// the screen it belonged to. This router outlives the swap, so the card can.
    /// The failure the picker's alert has already seen.
    ///
    /// Owned here rather than in `HostPickerView` so that `dismissConnecting()` can mark a
    /// failure shown on the ConnectingView as acknowledged before the picker becomes visible —
    /// otherwise the picker's alert fires for the same failure the moment the card fades away.
    @State private var acknowledgedFailure: String?
    /// A launch that is putting a Mac back holds a bare backdrop for a moment instead of animating
    /// Connect in, because on the same network the Mac is usually back before the moment is up.
    @State private var holdsLaunch = UserDefaults.standard.bool(forKey: SessionModel.resumeKey)
    /// Whether the launch's own attempt is still the one under way, so its failure stays quiet.
    @State private var isLaunchRestore = UserDefaults.standard.bool(forKey: SessionModel.resumeKey)
    private static let launchHold: Duration = .seconds(1)
    @State private var showsConnecting = false
    @State private var connectingSince: Date?
    /// Why the attempt failed, once it has. Held here rather than left to the picker's alert:
    /// a failure that arrives while this card is up has to be said on the card, because the
    /// card is what the user is looking at.
    @State private var connectingFailure: String?
    /// Set when an attempt has run long enough that saying nothing would look like a hang.
    @State private var connectingIsSlow = false
    /// The successful handshake gets one legible beat before the veil lifts. This is separate
    /// from `showsConnecting`: removing the view and asking its transition to animate was easy
    /// for SwiftUI to fold into the simultaneous screen handover underneath it.
    @State private var connectingDidSucceed = false
    @State private var connectingIsFading = false
    @State private var slowTask: Task<Void, Never>?
    /// A successful connection may keep the card up briefly so it can be read. Stored so a
    /// failure arriving during that grace period can cancel the pending dismissal.
    @State private var connectingDismissTask: Task<Void, Never>?

    /// How long the connecting card stays up once a connection starts.
    ///
    /// Deliberately longer than the connection. A LAN handshake is over in a fraction of this,
    /// and the wait it is covering is real regardless — a TLS handshake and a certificate
    /// exchange with nothing to look at — so the card is given the time to be read as an
    /// arrival rather than a flicker. It is the one place in the app where waiting is the
    /// intended effect rather than a cost, and it is tuned here and nowhere else.
    private static let connectingShownFor: TimeInterval = 0.9

    /// How long a connection may take before the card stops pretending it is nearly there.
    ///
    /// A LAN connection is over in a fraction of a second and a relay one in a second or two, so
    /// this is well past anything normal — which is the point. It is not a timeout; nothing is
    /// cancelled at this mark. It is the moment the card stops saying "Connecting…" as though
    /// that were a description of something about to finish, and offers a way out instead.
    private static let connectingSlowAfter: TimeInterval = 12

    /// Long enough for the spinner-to-checkmark change to register, short enough that a slow
    /// connection does not make the user wait again after it has already finished.
    private static let connectingSuccessShownFor: TimeInterval = 0.28

    /// Exiting is a system response, so it is quieter than the modal's arrival.
    /// Opacity only: scaling the whole screen away makes the live desktop behind it appear to
    /// lurch forward at exactly the moment it should simply become available.
    ///
    /// The curve is the whole of this, and it used to be wrong. It was
    /// `timingCurve(0.23, 1, 0.32, 1)` — both control points pinned at y = 1, which is the
    /// definition of a front-loaded ease-out: by 13% of the duration 49% of the fade had happened,
    /// by 26% it was at 78%, and the last two thirds of the animation moved what was left. What
    /// that reads as is not a slow fade but a fast one followed by a stretch of nothing, which is
    /// why it looked like the card was cut rather than faded.
    ///
    /// `0.4, 0, 0.2, 1` is the standard symmetric ease: the slope is gentle at both ends, so the
    /// veil leaves at a rate the eye can follow from the first frame. Longer with it, because a
    /// curve that starts slowly needs the time to arrive — the two numbers are one decision.
    ///
    /// Still a timing curve rather than a spring, and that is deliberate:
    /// ``scheduleConnectingFade(after:allowFailure:)`` sleeps for exactly this long before removing
    /// the view, and a timing curve finishes at its duration where a spring finishes when it
    /// settles. Those cannot be made to agree for a spring, and a sleep that outlives its animation
    /// is an invisible full-screen view still eating taps.
    private static let connectingFadeDuration: TimeInterval = 0.34
    private static let connectingFade = Animation.timingCurve(
        0.4, 0, 0.2, 1,
        duration: connectingFadeDuration
    )

    var body: some View {
        // A `ZStack`, not the `Group` this was, and the difference is the whole of the transition.
        //
        // A `Group` is transparent: its modifiers are applied to each branch separately rather
        // than to a container around them, so when the branch changes there is nothing that
        // survives the swap. No container whose frame could be interpolated, and never two views
        // on screen at once to carry an insertion and a removal together — the branch simply
        // changed. What that produces is a cross-fade, which is what a screen change looks like
        // when nobody designed it. A container has an identity that lasts through the change, so
        // both screens are briefly real and each can move on its own.
        ZStack {
            // A session outranks the introduction, and the order is load-bearing rather than
            // tidy. Two things connect without anyone tapping anything — the widget's
            // `peering://connect` URL, and the automatic resume on a Mac coming back into range
            // — so a first launch that was also a resume would otherwise land on a welcome
            // screen with a live session behind it.
            if isRemoteScreen {
                RemoteScreen()
                    .transition(Self.screenHandover)
            } else if !hasSeenWelcome {
                WelcomeFlow {
                    withAnimation(Motion.settle) { hasSeenWelcome = true }
                    model.startBrowsing()
                }
                    // The last page of the introduction shows the plans, so the store has to
                    // reach it — the same injection the paywall gets, for the same reason.
                    .environment(model.storeManager)
                    .transition(.opacity)
            } else if holdsLaunch {
                ColorPalette.backdrop.ignoresSafeArea()
            } else {
                HostPickerView(acknowledgedFailure: $acknowledgedFailure)
                    .transition(Self.screenHandover)
            }

            // Last in the stack, so it covers whichever screen is underneath — including the
            // moment the session replaces the picker. Nothing below it is reachable while it
            // is up: a tap during a handshake that found the list would start a second
            // connection for the same reason the first one was started.
            if showsConnecting {
                ConnectingView(
                    hostName: model.hostName,
                    failure: connectingFailure,
                    isSlow: connectingIsSlow,
                    isConnected: connectingDidSucceed,
                    onDismiss: dismissConnecting,
                    onCancel: cancelConnecting
                )
                // The exit is explicit rather than delegated to a removal transition. Keeping
                // the full-screen veil mounted until opacity reaches zero makes the handoff
                // deterministic even while the picker underneath becomes the remote screen.
                .opacity(connectingIsFading ? 0 : 1)
                // And it stops taking taps as soon as it starts leaving. Opacity is a paint, not
                // a permission: without this the veil is invisible for the whole fade and still
                // swallowing every touch, so the first thing the user does on the freshly arrived
                // screen — tap the thing they were waiting for — does nothing at all.
                //
                // Only during the exit. While the card is up it keeps its hit testing, which is
                // what stops a tap during a handshake from finding the list underneath and
                // starting a second connection.
                .allowsHitTesting(!connectingIsFading)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 1.04))
                )
            }
        }
        // Keyed to the connecting phases, not to `model.isBusy` — and that was the bug that made
        // this stick. `isBusy` answers "is a session live", which is true for `.ready` as well,
        // so a connection that *succeeded* never switched it off and the card stayed up over the
        // session it had just announced. The question this needs answered is narrower: is the
        // app in the part of a connection that has nothing to show yet.
        .onChange(of: isConnectingPhase, initial: true) { _, connecting in
            connecting ? beginConnecting() : endConnecting()
        }
        .task {
            guard holdsLaunch else { return }
            try? await Task.sleep(for: Self.launchHold)
            withAnimation(Motion.settle) { holdsLaunch = false }
        }
        .onChange(of: model.phase) { _, phase in
            guard isLaunchRestore else { return }
            switch phase {
            case .ready:
                isLaunchRestore = false
            case .failed(let message):
                // The Mac is not there, which is not news worth a card: Connect already shows it.
                acknowledgedFailure = message
                isLaunchRestore = false
                withAnimation(Motion.settle) { holdsLaunch = false }
            default:
                break
            }
        }
        // A failure that lands while the card is up belongs on the card, because the card is
        // what the user is looking at. Left to the picker's alert it would appear over the top
        // of this, having been written for a screen the user can no longer see.
        .onChange(of: model.phase) { _, phase in
            guard case .failed(let message) = phase, showsConnecting else { return }
            connectingDismissTask?.cancel()
            connectingDismissTask = nil
            withAnimation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle) {
                connectingIsFading = false
                connectingDidSucceed = false
                connectingFailure = message
            }
        }
        // Keyed to the arrival of a session rather than to `phase`, which changes several times
        // on the way in. Connecting and handshaking are the same screen still being looked at;
        // the change worth animating is the one where the picture takes over.
        .animation(Motion.settle, value: isRemoteScreen)
        .animation(Motion.settle, value: hasSeenWelcome)
        .onChange(of: isRemoteScreen, initial: true) { _, remote in
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            // The mask is what *permits* rotation, and it is read through
            // `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`.
            OrientationLock.shared.allowed = isPad
                ? .all
                : (remote ? .allButUpsideDown : .portrait)

            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            else { return }

            // Writing the mask is not enough, and this is the line that was missing.
            // UIKit consults the delegate at its own discretion and otherwise keeps the
            // value it last read — which was `.portrait`, set by the landing screen. So
            // the remote screen went on offering portrait while `allowed` said otherwise,
            // and no geometry request could fix that: the mask still excluded landscape.
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()

            // Only the landing screen asks for an actual rotation. On the remote screen
            // the device decides — requesting a geometry there would name the orientation
            // the phone is already in (portrait, a member of the allowed set) and read as
            // "stay put", which is what made rotation look disabled while sharing.
            if !remote, !isPad {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        // Presented from the top level rather than from whichever screen asked for it, so the
        // paywall is the same screen with the same animation however the user got here — and so
        // that opening it does not depend on the screen underneath still being on display.
        //
        // Not the only place it is attached: a lock that lives inside a sheet needs a presenter
        // inside that sheet, because a sheet cannot be presented over itself. See
        // ``SwiftUI/View/presentsPaywall(_:)``.
        .presentsPaywall(model)
        // The other sheet, and a different one on purpose. A session the relay ended for spent
        // allowance is not a wall the user walked into, so it does not open the purchase screen:
        // it opens an explanation with the plans one tap away. See ``AllowanceSpentView``.
        //
        // Its own presentation rather than a branch inside the one above, because they are two
        // different screens with two different doors and only one of them is selling anything.
        .sheet(isPresented: Binding(
            get: { model.spentAllowance != nil },
            set: { if !$0 { model.dismissSpentAllowance() } }
        )) {
            AllowanceSpentView(
                plan: model.spentAllowance ?? .free,
                onDismiss: { model.dismissSpentAllowance() }
            )
            .environment(model.storeManager)
            .preferredColorScheme(.dark)
        }
    }

    /// Whether the app is in the part of a connection that has nothing to show yet.
    ///
    /// `.confirming` is deliberately excluded: by then there is a pairing code on screen and the
    /// session's own screen is the right place for it, so the card has already done its job.
    private var isConnectingPhase: Bool {
        switch model.phase {
        case .connecting, .handshaking: return true
        default: return false
        }
    }

    private func beginConnecting() {
        // **A resume gets no card, and this is the whole of why.** The card exists to cover the
        // part of a connection that has nothing to look at yet, and its 0.9s hold is tuned for a
        // Mac being opened, where being read as an arrival rather than a flicker is the point. A
        // resume has a picture already on screen underneath and someone who was watching it. The
        // screen it comes back to is still up, so there is nothing here to cover and no reason to
        // make them wait for the ritual.
        //
        // Asked of the session, for the reason ``isRemoteScreen`` asks there: a resume is a resume
        // whether or not a session object survived to say so, and the card is not the only modal
        // this would otherwise be.
        guard !model.isBeingPutBack else { return }

        connectingDismissTask?.cancel()
        connectingDismissTask = nil
        connectingSince = Date()
        connectingFailure = nil
        connectingIsSlow = false
        connectingDidSucceed = false
        connectingIsFading = false

        slowTask?.cancel()
        slowTask = Task {
            try? await Task.sleep(for: .seconds(Self.connectingSlowAfter))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.settle) { connectingIsSlow = true }
        }

        withAnimation(Motion.settle) { showsConnecting = true }
    }

    /// Closes the card after a failure has been read.
    private func dismissConnecting() {
        // Mark the failure as seen before the card fades away. Without this the picker's own
        // alert fires for the same message the instant the card is gone, because the phase stays
        // `.failed` until the next attempt and the picker has never set its own acknowledged flag.
        acknowledgedFailure = model.failureMessage
        connectingSince = nil
        slowTask?.cancel()
        slowTask = nil
        scheduleConnectingFade(after: 0, allowFailure: true)
    }

    /// Abandons an attempt that is going nowhere.
    ///
    /// The session's own disconnect rather than this view giving up on its own: the attempt is
    /// real, with a socket open and a handshake half-done, and closing the card without telling
    /// it would leave the connection running behind a screen that claims nothing is happening.
    private func cancelConnecting() {
        model.disconnect()
        dismissConnecting()
    }

    /// Takes the card down, once it has been up long enough to be read.
    ///
    /// The floor is the point rather than a side effect: the connection it describes finishes
    /// long before anyone could register that it started. Nothing is waiting on it — the
    /// session behind it is already up, or has already failed — and the card says the same
    /// thing either way, which is honest: at that moment neither the app nor the user knows
    /// yet which it was.
    private func endConnecting() {
        slowTask?.cancel()
        slowTask = nil

        // `isConnectingPhase` and `model.phase` are observed separately. SwiftUI does not
        // promise which `onChange` runs first, so read the source of truth here instead of
        // assuming the failure handler has already copied its message into local state.
        if case .failed(let message) = model.phase {
            connectingDismissTask?.cancel()
            connectingDismissTask = nil
            withAnimation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle) {
                connectingIsFading = false
                connectingDidSucceed = false
                connectingFailure = message
            }
            return
        }

        // A failure keeps the card up until it has been read, because it is the only place the
        // reason is shown. Everything else comes down on schedule — there is nothing on it to
        // look at, and the session behind it is already up.
        guard connectingFailure == nil else { return }

        guard let since = connectingSince else { return }
        let remaining = max(0, Self.connectingShownFor - Date().timeIntervalSince(since))
        let reachedReady = model.phase == .ready

        if reachedReady {
            connectingIsSlow = false
            withAnimation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle) {
                connectingDidSucceed = true
            }
        }

        scheduleConnectingFade(
            after: reachedReady
                ? max(remaining, Self.connectingSuccessShownFor)
                : remaining
        )
    }

    /// Runs the fade before removing the view. The old removal transition asked SwiftUI to
    /// preserve a disappearing branch while another animated branch changed underneath it;
    /// explicitly sequencing the opacity and removal means neither transaction can swallow the
    /// other. Only opacity moves during the exit, so the live desktop never appears to zoom.
    private func scheduleConnectingFade(after delay: TimeInterval, allowFailure: Bool = false) {
        connectingDismissTask?.cancel()
        connectingDismissTask = Task {
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
            } catch {
                return
            }
            guard allowFailure || connectingFailure == nil else { return }

            withAnimation(Self.connectingFade) { connectingIsFading = true }
            do {
                try await Task.sleep(for: .seconds(Self.connectingFadeDuration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            // Opacity is already zero. Removing without another transition prevents a second,
            // invisible animation from holding this full-screen hit target over the desktop.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { showsConnecting = false }
            connectingSince = nil
            connectingIsSlow = false
            connectingDidSucceed = false
            connectingIsFading = false
            connectingDismissTask = nil
        }
    }
}

/// The screen shown while a connection is being made.
///
/// Full-screen and on the app's own backdrop, not a card floating over a dimmed list. A card
/// over a list is a dialogue, and this is not a question being asked — it is the arrival, and
/// it should look like the app has gone somewhere. The soft light is the same one every other
/// screen in the app is lit by.
///
/// **It has four states, and the middle two exist because the first one lied.** A screen that
/// says "Connecting…" and nothing else is indistinguishable from a screen that has hung, and
/// there was no way out of it: a Mac that never answers left it up forever with no message and
/// no escape. So a slow attempt says so and offers a way out, a failed one says what went wrong
/// and stays until it is read, and success gets a brief checkmark before the desktop is revealed.
/// The Mac and the iPhone, with the link running between them.
///
/// This was a decoration on the Connect screen's header, and it was wasted there: the dots between
/// the two devices are the only part of the drawing that has anything to say, and what they say —
/// these two are reaching for each other — is only true while something is connecting. So it lives
/// on the connecting card now, which is the moment it was drawing all along.
///
/// `scale` multiplies every measurement in it rather than there being a second drawing at another
/// size. Two copies of a pair of devices is two pairs of proportions, and the difference shows up
/// as one of them looking subtly wrong beside the other.
///
/// **The devices are `MacDrawing` and `PhoneDrawing`, the tour's own frames, at icon size.** This
/// used to be a hand-drawn sketch: a translucent bar with a stand standing in for the Mac, a
/// gradient-filled rounded rectangle for the phone, neither of them related to the machines the
/// onboarding tour and the marketing site agree on. Two drawings of "a Mac" and "an iPhone" in one
/// app is two claims about what these machines look like, and a lid with no base and a bezel with
/// no rim were not the shapes the rest of the app had already settled on.
private struct DeviceLinkArtwork: View {
    var scale: CGFloat = 1

    var body: some View {
        // Twenty frames a second rather than one per screen refresh, and it costs nothing to look
        // at. Both movements here are a slow drift and a slow pulse over several seconds; the
        // difference between that at 20Hz and at 120Hz is not visible, and the difference in what
        // it costs to redraw a TimelineView on every frame is very much there.
        //
        // A timeline rather than a repeating animation, see ``Wordmark`` in `HostPickerView` for
        // what a `repeatForever` loop does when a re-layout lands on top of it.
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10 * scale) {
                mac.offset(y: wave(now, period: 5.2) * 1.6 * scale)
                dots(at: now)
                phone.offset(y: wave(now, period: 6.4, phase: 0.35) * 1.6 * scale)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var mac: some View {
        MacDrawing(displayHeight: 24 * scale) {
            ColorPalette.surface
                .overlay {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 9 * scale, weight: .medium))
                        .foregroundStyle(ColorPalette.ink)
                }
        }
    }

    /// The screen takes ``ColorPalette/surface``, the same material as the Mac's, so the two
    /// devices are lit the same way and read as a pair rather than as two drawings.
    private var phone: some View {
        PhoneDrawing(screenWidth: 19 * scale) {
            ColorPalette.surface
        }
    }

    private func dots(at now: TimeInterval) -> some View {
        HStack(spacing: 4 * scale) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(ColorPalette.ink)
                    .frame(width: 3 * scale, height: 3 * scale)
                    .opacity(
                        0.42 + 0.42 * wave(
                            now,
                            period: 1.5,
                            phase: -Double(index) * (0.25 / 1.5)
                        )
                    )
            }
        }
    }

    private func wave(_ now: TimeInterval, period: Double, phase: Double = 0) -> CGFloat {
        CGFloat(sin(2 * .pi * (now / period + phase)))
    }
}

private struct ConnectingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let hostName: String?
    /// The reason the connection failed, once there is one.
    var failure: String?
    /// Whether the attempt has been running long enough to be worth commenting on.
    var isSlow: Bool
    /// True only after an already-paired Mac reaches `.ready`. First-time pairing moves on to
    /// its code instead, so it never claims success before the person has confirmed it.
    var isConnected: Bool
    var onDismiss: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()

            RadialGradient(
                colors: [.white.opacity(0.07), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 460
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                // The two devices, mid-handshake, where a lone Mac used to be. A single glyph said
                // "a Mac" on the one screen whose whole subject is *two* things and what is passing
                // between them — and the dots running between these two are the connection being
                // made, at the size the drawing was always meant to be seen at.
                //
                // It stays put when the attempt fails, and only the glyph on top of it changes:
                // the slot is a fixed height so a failure does not shift the name and the
                // sentence under it by thirty points, which is the sort of jump that reads as the
                // card having been rebuilt rather than as a message appearing on it.
                ZStack {
                    if failure == nil {
                        DeviceLinkArtwork(scale: 1.8)
                            .transition(.opacity)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 46, weight: .light))
                            .foregroundStyle(ColorPalette.ink)
                            .transition(.opacity)
                    }
                }
                .frame(height: 92)

                VStack(spacing: 7) {
                    Text(hostName ?? "Your Mac")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(
                            failure == nil
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(ColorPalette.ink.opacity(0.85))
                        )
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)

                if let failure {
                    Button("Dismiss", action: onDismiss)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(ColorPalette.ink)
                        .foregroundStyle(.black)
                        .accessibilityHint(failure)
                } else if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(ColorPalette.accent)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.92))
                        )
                        .accessibilityLabel("Connected")
                } else if isSlow {
                    // The escape hatch. Nothing above this is wrong yet, but a Mac that is not
                    // answering will not start answering because the user waited longer, and a
                    // screen with no way off it is the worst version of this one.
                    Button("Give up", action: onCancel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .buttonStyle(RailButtonStyle(scale: 0.98))
                } else {
                    ConnectingSpinner()
                }
            }
            .padding(.horizontal, 40)
            .animation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle, value: failure != nil)
            .animation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle, value: isSlow)
            .animation(reduceMotion ? .easeOut(duration: 0.16) : Motion.settle, value: isConnected)
        }
        .allowsHitTesting(true)
    }

    private var detail: String {
        if let failure { return failure }
        if isConnected { return "Connected" }
        return isSlow ? "Still trying. The Mac has not answered yet." : "Connecting…"
    }
}

/// A spinner of the app's own, rather than the system's.
///
/// The stock indicator is a grey ring in the style every app on the phone uses, and this is the
/// one screen in the app that exists to say it has gone somewhere else — borrowing another
/// app's furniture is most obviously wrong here. An arc on the app's own backdrop is one shape
/// and no image assets.
///
/// `repeatForever` on the shape itself rather than on any view above it. A repeating animation
/// placed on an ancestor captures the layout of everything beneath it, which is the trap this
/// codebase has already been caught by once — see ``DeviceLinkArtwork``.
private struct ConnectingSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(ColorPalette.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 30, height: 30)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: spinning
            )
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}

#Preview {
    ContentView()
        .environment(SessionModel())
}
