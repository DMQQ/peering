import SwiftUI

@main
struct PeeringWatchApp: App {
    @State private var store = ApprovalStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ApprovalListView()
                .environment(store)
                .task { store.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await store.refresh() } }
                }
        }
    }
}
