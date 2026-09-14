import SwiftUI

@main
struct MacCastHostApp: App {
    /// The window is reopened from the menu bar, which needs something to name it by once the
    /// user has closed it — closing a window must not take the host down with it.
    static let mainWindowID = "main"

    @State private var model = HostModel()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            HostStatusView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        // The connection state is read here rather than inside the label because an
        // `@Observable` read in a scene body is what invalidates the scene.
        MenuBarExtra {
            HostMenuBarContent()
                .environment(model)
        } label: {
            HostMenuBarLabel(connected: !model.connectedClients.isEmpty)
        }
        .menuBarExtraStyle(.menu)
    }
}
