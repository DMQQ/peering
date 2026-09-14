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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { model.start() }
                // The screen may lock or the app may be backgrounded while the Mac is still
                // connected. Nothing here tears the session down: iOS keeps the sockets alive
                // briefly and `NWConnection` reconnects around a Wi-Fi hiccup, so dropping the
                // connection on every backgrounding would turn a glance at another app into a
                // full re-pair.
                .preferredColorScheme(.dark)
        }
    }
}
