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
}

#Preview {
    ContentView()
        .environment(SessionModel())
}
