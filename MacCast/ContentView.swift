import RemoteCore
import SwiftUI
import UIKit

/// The root. Two screens, and which one is showing is a direct function of the session phase —
/// there is no separate "am I connected" flag that could disagree with the phase.
struct ContentView: View {
    @Environment(SessionModel.self) private var model

    /// Whether the first-run introduction has been seen.
    ///
    /// The second question this router asks, and deliberately a separate one from the first.
    /// `phase` answers "is there a session"; this answers "has this person been here before" —
    /// and the two are unrelated, which is why they are two branches rather than one condition
    /// with an `&&` in it.
    @AppStorage(PreferenceKey.hasSeenWelcome) private var hasSeenWelcome = false

    private var isRemoteScreen: Bool {
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
    @State private var showsConnecting = false
    @State private var connectingSince: Date?
    /// Why the attempt failed, once it has. Held here rather than left to the picker's alert:
    /// a failure that arrives while this card is up has to be said on the card, because the
    /// card is what the user is looking at.
    @State private var connectingFailure: String?
    /// Set when an attempt has run long enough that saying nothing would look like a hang.
    @State private var connectingIsSlow = false
    @State private var slowTask: Task<Void, Never>?

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
                WelcomeFlow { withAnimation(Motion.settle) { hasSeenWelcome = true } }
                    .transition(.opacity)
            } else {
                HostPickerView()
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
                    onDismiss: dismissConnecting,
                    onCancel: cancelConnecting
                )
                .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        // One spring for both halves of the handover: the screen changing underneath and the
        // card arriving over it.
        .animation(Motion.settle, value: showsConnecting)
        // Keyed to the connecting phases, not to `model.isBusy` — and that was the bug that made
        // this stick. `isBusy` answers "is a session live", which is true for `.ready` as well,
        // so a connection that *succeeded* never switched it off and the card stayed up over the
        // session it had just announced. The question this needs answered is narrower: is the
        // app in the part of a connection that has nothing to show yet.
        .onChange(of: isConnectingPhase, initial: true) { _, connecting in
            connecting ? beginConnecting() : endConnecting()
        }
        // A failure that lands while the card is up belongs on the card, because the card is
        // what the user is looking at. Left to the picker's alert it would appear over the top
        // of this, having been written for a screen the user can no longer see.
        .onChange(of: model.phase) { _, phase in
            guard case .failed(let message) = phase, showsConnecting else { return }
            withAnimation(Motion.settle) { connectingFailure = message }
        }
        // Keyed to the arrival of a session rather than to `phase`, which changes several times
        // on the way in. Connecting and handshaking are the same screen still being looked at;
        // the change worth animating is the one where the picture takes over.
        .animation(Motion.settle, value: isRemoteScreen)
        .animation(Motion.settle, value: hasSeenWelcome)
        .onChange(of: isRemoteScreen, initial: true) { _, remote in
            // The mask is what *permits* rotation, and it is read through
            // `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`.
            OrientationLock.shared.allowed = remote ? .allButUpsideDown : .portrait

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
            if !remote {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
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
        connectingSince = Date()
        connectingFailure = nil
        connectingIsSlow = false

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
        connectingSince = nil
        connectingFailure = nil
        slowTask?.cancel()
        slowTask = nil
        withAnimation(Motion.settle) { showsConnecting = false }
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

        // A failure keeps the card up until it has been read, because it is the only place the
        // reason is shown. Everything else comes down on schedule — there is nothing on it to
        // look at, and the session behind it is already up.
        guard connectingFailure == nil else { return }

        guard let since = connectingSince else { return }
        let remaining = Self.connectingShownFor - Date().timeIntervalSince(since)
        guard remaining > 0 else {
            connectingSince = nil
            withAnimation(Motion.settle) { showsConnecting = false }
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(remaining))
            connectingSince = nil
            connectingIsSlow = false
            withAnimation(Motion.settle) { showsConnecting = false }
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
/// **It has three states, and the last two exist because the first one lied.** A screen that
/// says "Connecting…" and nothing else is indistinguishable from a screen that has hung, and
/// there was no way out of it: a Mac that never answers left it up forever with no message and
/// no escape. So a slow attempt says so and offers a way out, and a failed one says what went
/// wrong and stays until it is read.
private struct ConnectingView: View {
    let hostName: String?
    /// The reason the connection failed, once there is one.
    var failure: String?
    /// Whether the attempt has been running long enough to be worth commenting on.
    var isSlow: Bool
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
                Image(systemName: failure == nil ? "macbook" : "exclamationmark.triangle")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(ColorPalette.ink)
                    .contentTransition(.symbolEffect(.replace))

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
            .animation(Motion.settle, value: failure != nil)
            .animation(Motion.settle, value: isSlow)
        }
        .allowsHitTesting(true)
    }

    private var detail: String {
        if let failure { return failure }
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
