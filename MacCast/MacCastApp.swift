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
                .task { model.start() }
                // The banners are for a user who is somewhere else. Coming back to the front
                // is the moment they stop being the current news: the screen says the same
                // thing, and the banner sitting behind it is a claim about the past — a
                // pairing prompt from last night is the case this exists to prevent.
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        SessionNotifier.shared.retractAll()
                        model.enteringForeground()
                    case .inactive:
                        // The last moment the app's view hierarchy is still on screen, and so
                        // the last moment `startPictureInPicture` can lift the video layer out
                        // of it. Asking at `.background` — which is what this did — is a
                        // refusal, because by then there is nothing to lift it from.
                        //
                        // It fires for things that are not leaving, too: Control Center, a
                        // banner, the app switcher opening. Those cost a PiP window that has to
                        // be dismissed, which is the price of the one case that matters.
                        model.leavingScreen()
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
                    model.reconnectToLastHost()
                }
                .preferredColorScheme(.dark)
        }
    }
}
