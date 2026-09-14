import RemoteCore
import SwiftUI

@main
struct MacCastApp: App {
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
