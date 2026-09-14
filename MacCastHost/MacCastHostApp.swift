import SwiftUI

@main
struct MacCastHostApp: App {
    @State private var model = HostModel()

    var body: some Scene {
        WindowGroup {
            HostStatusView()
                .environment(model)
        }
        .windowResizability(.contentSize)
    }
}
