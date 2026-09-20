import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

// Singleton so the AppDelegate and any view can agree on the current allowed orientations.
final class OrientationLock {
    static let shared = OrientationLock()
    private init() {}
    var allowed: UIInterfaceOrientationMask = .portrait
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.allowed
    }
}

@main
struct MacCastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// One session for the app's life.
    ///
    /// Owned here rather than by a view, because the thing it represents — a connection to a
    /// Mac, with a certificate identity and a command queue behind it — outlives any screen.
    /// A model created by `HostPickerView` would be destroyed the moment the picker left the
    /// hierarchy, which is precisely when the connection starts being used.
    @State private var model = SessionModel()
    /// The SSH side's model, owned here for the same reason and one more: an intent has no view
    /// hierarchy to read it from, and "open a shell on prod" arrives before any screen exists to
    /// have made one.
    @State private var servers = SSHModel()
    /// The commands both terminals keep one tap away, owned here because both read them.
    @State private var quickCommands = QuickCommands()
    @AppStorage(PreferenceKeys.hasSeenWelcome) private var hasSeenWelcome = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SecuredRootView {
                ContentView()
            }
                // Sideways, a screen may only move if it has somewhere to go.
                //
                // Every screen here is a vertical scroll view, and iOS gives one of those a bounce
                // on both axes whether or not there is anything to the side — so a tab whose
                // content is exactly the width of the phone still slides under a thumb dragged
                // across it, and comes back. It reads as a layout that has come loose, and on a
                // screen that is only ever scrolled down it is a movement with no meaning at all.
                //
                // `.basedOnSize` rather than `.never`, so this is a rule and not a ban: the two
                // places in the app that genuinely scroll sideways — the tour's pages and the
                // terminal — keep the movement they are made of. It sits here, on the root, because
                // the value travels down through the environment to every scroll view beneath it,
                // including the screens pushed from a tab and the sheets presented over one.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .environment(model)
                .environment(servers)
                .environment(quickCommands)
                .task {
                    model.start()
                    await model.storeManager.start()
                    // Handed over once, so Siri and Shortcuts have something to reach. The
                    // intents cannot read a view hierarchy and the model is owned here, not by
                    // a view — see ``IntentHost``.
                    IntentHost.model = model
                    IntentHost.servers = servers
                    // Browsing triggers the local network permission prompt. Defer it until
                    // after the welcome flow so a first-run user sees onboarding first.
                    if hasSeenWelcome {
                        model.startBrowsing()
                    }
                }
                // The plan, into the object that floats the picture, as soon as the App Store
                // answers and again whenever the answer changes under a running app: a
                // subscription bought, renewed or lapsed while this process is up.
                //
                // **PiP is the one paid capability that cannot wait for a tap.** Every other
                // gate in the app is asked by a control the user is looking at; this one is
                // armed in advance and spends itself when the app is *left*, which is a gesture
                // rather than a press and has no moment at which a gate could ask. So the
                // answer is pushed in on every change instead, and the object that holds the
                // controller keeps the last one. See ``SessionPiP/isOnPlan``.
                .onChange(of: model.storeManager.access) { _, _ in
                    model.applyPictureInPicturePlan()
                }
                // The banners are for a user who is somewhere else. Coming back to the front
                // is the moment they stop being the current news: the screen says the same
                // thing, and the banner sitting behind it is a claim about the past — a
                // pairing prompt from last night is the case this exists to prevent.
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        SessionNotifier.shared.retractAll()
                        model.enteringForeground()
                    case .background:
                        // Asks for the few seconds iOS grants before it suspends an app. The
                        // session still ends when that runs out — see
                        // ``SessionModel/backgroundTimeExpired()`` — but it ends *tidy*, with
                        // the Mac told and the Live Activity taken down, instead of a socket
                        // dying unobserved and a Lock Screen card left claiming otherwise.
                        model.enteringBackground()
                    default:
                        break
                    }
                }
                // The home-screen widget cannot connect anything itself — the session, the
                // identity and the sockets all live in this process — so it hands over with the
                // one instruction it can give.
                .onOpenURL { url in
                    guard url.scheme == "peering", url.host == "connect" else { return }

                    // The widget's medium size names a Mac per row, so the URL carries which one
                    // was asked for. Without an id — the small tile, which has only one thing it
                    // could mean — this is the Mac used last, which is what it always was.
                    let requested = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .first { $0.name == "id" }?
                        .value

                    if let requested, model.pairedHostIDs.contains(requested) {
                        model.connectToTrusted(hostID: requested)
                    } else {
                        model.reconnectToLastHost()
                    }
                }
                .preferredColorScheme(.dark)
        }
    }
}
