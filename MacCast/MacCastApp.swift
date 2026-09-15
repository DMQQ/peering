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

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    model.start()
                    // Handed over once, so Siri and Shortcuts have something to reach. The
                    // intents cannot read a view hierarchy and the model is owned here, not by
                    // a view — see ``IntentHost``.
                    IntentHost.model = model
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
