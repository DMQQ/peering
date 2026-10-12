import MacCastKit
import RemoteCore
import StoreKit
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.requestReview) private var requestReview

    @AppStorage(PreferenceKeys.hasSeenWelcome) private var hasSeenWelcome = false
    @AppStorage(PreferenceKeys.hasDismissedFirstConnection) private var hasDismissedFirstConnection = false

    /// The first-connection guide owns the screen until the first Mac is paired, including the handshake and the code (a pairing in progress holds it even once the pin is written, so the picker never flashes between the guide and the session).
    private var coversPairing: Bool {
        guard hasSeenWelcome, !hasDismissedFirstConnection else { return false }
        switch model.phase {
        case .confirming: return true
        default: return model.pins.isEmpty
        }
    }

    private var isRemoteScreen: Bool {
        // A drop leaves the phase at `.failed`, which used to unmount this subtree and lose the zoom, open panel and dock. A session being resumed (``MacSession/isResumingAfterDrop``, ``MacSession/isBeingPutBack``) keeps this screen; one the user stepped away from (``SessionModel/isSessionOnScreen``) does not, and that is checked first.
        guard model.isSessionOnScreen else { return false }
        if model.isBeingPutBack {
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

    private static let screenHandover = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 1.06, anchor: .center)),
        removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .center))
    )

    /// Owned here, not by the picker: the picker is removed the moment the session is ready, which would destroy the card mid-read. Also holds the failure the picker's alert has already seen.
    @State private var acknowledgedFailure: String?
    @State private var holdsLaunch = UserDefaults.standard.bool(forKey: SessionModel.resumeKey)
    @State private var isLaunchRestore = UserDefaults.standard.bool(forKey: SessionModel.resumeKey)
    private static let launchHold: Duration = .seconds(1)
    /// Whether the pairing now under way is the first Mac's, noted when the code is asked for because by the time it ends the pin is written and the guide no longer covers it.
    @State private var pairingIsFirst = false
    @State private var celebratesPairing = false
    @State private var showsConnecting = false
    @State private var connectingSince: Date?
    @State private var connectingFailure: String?
    @State private var connectingIsSlow = false
    @State private var connectingDidSucceed = false
    @State private var connectingIsFading = false
    @State private var slowTask: Task<Void, Never>?
    @State private var connectingDismissTask: Task<Void, Never>?

    /// Deliberately longer than the connection: a LAN handshake is instant, and the card needs time to read as an arrival rather than a flicker.
    private static let connectingShownFor: TimeInterval = 0.9

    /// Not a timeout and nothing is cancelled: past this the card stops saying Connecting and offers a way out.
    private static let connectingSlowAfter: TimeInterval = 12

    private static let connectingSuccessShownFor: TimeInterval = 0.28

    /// Opacity only: scaling the screen away makes the desktop behind it lurch. The curve is the standard symmetric ease; a front-loaded ease-out read as a cut.
    /// A timing curve rather than a spring because ``scheduleConnectingFade(after:allowFailure:)`` sleeps for exactly this long, and a sleep outliving its animation leaves an invisible view eating taps.
    private static let connectingFadeDuration: TimeInterval = 0.34
    private static let connectingFade = Animation.timingCurve(
        0.4, 0, 0.2, 1,
        duration: connectingFadeDuration
    )

    var body: some View {
        // A ZStack, not a Group: a Group is transparent, so a branch change has no container to interpolate and only cross-fades.
        ZStack {
            // A session outranks the introduction (load-bearing order): the widget URL and automatic resume connect without a tap, so a first launch that is also a resume would otherwise land on welcome with a live session behind it.
            // One branch for the guide and its last beat, so the same view carries on rather than being replaced by another: its steps stay where they are and tick to done.
            if coversPairing || celebratesPairing {
                FirstConnectionScreen(isConnected: celebratesPairing) { withAnimation(Motion.settle) { hasDismissedFirstConnection = true } }
                    .transition(.opacity)
            } else if isRemoteScreen {
                RemoteScreen()
                    .transition(Self.screenHandover)
            } else if !hasSeenWelcome {
                WelcomeFlow {
                    withAnimation(Motion.settle) {
                        // Finishing the tour, first time or replayed, is when the guide is owed: a "later" tapped on an earlier run must not swallow it.
                        hasDismissedFirstConnection = false
                        hasSeenWelcome = true
                    }
                    model.startBrowsing()
                }
                    .environment(model.storeManager)
                    .transition(.opacity)
            } else if holdsLaunch {
                ColorPalette.backdrop.ignoresSafeArea()
            } else {
                HostPickerView(acknowledgedFailure: $acknowledgedFailure)
                    .transition(Self.screenHandover)
            }

            // Last in the stack so it covers whichever screen is underneath, including the moment the session replaces the picker.
            if showsConnecting {
                ConnectingView(
                    hostName: model.shownHostName,
                    failure: HostWireText.localized(connectingFailure),
                    isSlow: connectingIsSlow,
                    isConnected: connectingDidSucceed,
                    onDismiss: dismissConnecting,
                    onCancel: cancelConnecting
                )
                .opacity(connectingIsFading ? 0 : 1)
                // Stops taking taps as soon as it starts leaving: opacity is a paint, not a permission. While up it keeps hit testing so a tap during a handshake cannot start a second connection.
                .allowsHitTesting(!connectingIsFading)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 1.04))
                )
            }
        }
        // Keyed to the connecting phases, not `model.isBusy`: isBusy is also true for `.ready`, which left the card up over a session that had succeeded.
        .onChange(of: isConnectingPhase, initial: true) { _, connecting in
            connecting ? beginConnecting() : endConnecting()
        }
        .task {
            guard holdsLaunch else { return }
            try? await Task.sleep(for: Self.launchHold)
            withAnimation(Motion.settle) { holdsLaunch = false }
        }
        .onChange(of: model.phase) { old, new in
            if case .confirming = new { pairingIsFirst = coversPairing }
            if case .confirming = old, new == .ready, pairingIsFirst {
                pairingIsFirst = false
                celebratePairing()
            }
        }
        .onChange(of: model.phase) { _, phase in
            guard isLaunchRestore else { return }
            switch phase {
            case .ready:
                isLaunchRestore = false
            case .failed(let message):
                acknowledgedFailure = message
                isLaunchRestore = false
                withAnimation(Motion.settle) { holdsLaunch = false }
            default:
                break
            }
        }
        // A failure that lands while the card is up belongs on the card; the picker's alert is for a screen the user can no longer see.
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
        // Keyed to a session arriving, not `phase`, which changes several times on the way in.
        .animation(Motion.settle, value: isRemoteScreen)
        .animation(Motion.settle, value: hasSeenWelcome)
        .onChange(of: isRemoteScreen, initial: true) { _, remote in
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            OrientationLock.shared.allowed = isPad
                ? .all
                : (remote ? .allButUpsideDown : .portrait)

            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            else { return }

            // Writing the mask is not enough: UIKit keeps the value it last read (`.portrait`, from the landing screen) unless told to re-read, so landscape stayed excluded.
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()

            // Only the landing screen requests a rotation. On the remote screen, requesting a geometry names the current orientation and reads as stay put, which made rotation look disabled.
            if !remote, !isPad {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        // Presented from the top level so the paywall behaves the same however the user got here. A lock inside a sheet needs its own presenter (see ``SwiftUI/View/presentsPaywall(_:)``).
        .presentsPaywall(model)
        .presentsWhatsNew()
        .onChange(of: model.wantsReviewPrompt) { _, wants in
            guard wants else { return }
            model.wantsReviewPrompt = false
            requestReview()
        }
        // A session ended for spent allowance is not a wall the user walked into, so it gets its own explanation sheet (``AllowanceSpentView``), not the purchase screen.
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

    /// `.confirming` is excluded: a pairing code is on screen by then and the session's own screen is the place for it.
    private var isConnectingPhase: Bool {
        switch model.phase {
        case .connecting, .handshaking: return true
        default: return false
        }
    }

    private func celebratePairing() {
        hasDismissedFirstConnection = true
        withAnimation(Motion.settle) { celebratesPairing = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1700))
            withAnimation(Motion.settle) { celebratesPairing = false }
        }
    }

    private func beginConnecting() {
        guard !coversPairing else { return }
        // A resume gets no card: a picture is already on screen and the 0.9s hold is tuned for opening a Mac. Asked of the session because a resume is a resume whether or not a session object survived.
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

    private func dismissConnecting() {
        // Mark the failure seen before the card fades: the phase stays `.failed` until the next attempt, so the picker's alert would fire for the same message.
        acknowledgedFailure = model.failureMessage
        connectingSince = nil
        slowTask?.cancel()
        slowTask = nil
        scheduleConnectingFade(after: 0, allowFailure: true)
    }

    /// The session's own disconnect: the socket is open and the handshake half-done, so closing only the card would leave it running.
    private func cancelConnecting() {
        model.disconnect()
        dismissConnecting()
    }

    /// A floor so the card can be read: the connection it covers finishes before anyone registers it started.
    private func endConnecting() {
        slowTask?.cancel()
        slowTask = nil

        // `isConnectingPhase` and `model.phase` are observed separately and onChange order is not promised, so read the source of truth here.
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

    /// Runs the fade before removing the view: the old removal transition let one transaction swallow the other. Only opacity moves, so the desktop never appears to zoom.
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

            // Opacity is already zero: removing without a transition avoids a second invisible animation holding the full-screen hit target.
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

/// The screen shown while a connection is being made. A slow attempt says so and offers a way out, a failure says what went wrong and stays until read, and success shows a checkmark before the reveal.
/// `scale` multiplies every measurement so there is one drawing, not two sets of proportions. The devices are `MacDrawing` and `PhoneDrawing` at icon size, so the app has one drawing of each machine.
private struct DeviceLinkArtwork: View {
    var scale: CGFloat = 1

    var body: some View {
        // Twenty frames a second is enough for a slow drift and pulse. A TimelineView rather than `repeatForever`, which a re-layout cancels (see ``Wordmark`` in `HostPickerView`).
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
    var failure: String?
    var isSlow: Bool
    /// True only after an already-paired Mac reaches `.ready`; first-time pairing moves on to its code, so it never claims success before confirmation.
    var isConnected: Bool
    var onDismiss: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()

            TopGlow()

            VStack(spacing: 26) {
                // The slot is a fixed height so a failure does not shift the name and sentence under it.
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
                    Text(hostName ?? String(localized: "Your Mac"))
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
        if isConnected { return String(localized: "Connected") }
        return isSlow
            ? String(localized: "Still trying. The Mac has not answered yet.")
            : String(localized: "Connecting…")
    }
}

/// `repeatForever` on the shape itself, not an ancestor: an ancestor's repeating animation captures the layout of everything beneath it (see ``DeviceLinkArtwork``).
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
