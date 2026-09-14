import RemoteCore
import SwiftUI
import UIKit

/// The root. Two screens, and which one is showing is a direct function of the session phase —
/// there is no separate "am I connected" flag that could disagree with the phase.
struct ContentView: View {
    @Environment(SessionModel.self) private var model

    private var isRemoteScreen: Bool {
        switch model.phase {
        case .ready, .confirming: return true
        default: return false
        }
    }

    var body: some View {
        Group {
            if isRemoteScreen {
                RemoteScreen()
            } else {
                HostPickerView()
            }
        }
        .animation(.default, value: model.phase)
        .onChange(of: isRemoteScreen, initial: true) { _, remote in
            OrientationLock.shared.allowed = remote ? .allButUpsideDown : .portrait
            // Request the orientation change from the window scene so the UI rotates
            // immediately rather than waiting for the next device movement.
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            let target: UIWindowScene.GeometryPreferences.iOS = remote
                ? .init(interfaceOrientations: .allButUpsideDown)
                : .init(interfaceOrientations: .portrait)
            scene.requestGeometryUpdate(target)
        }
    }
}

#Preview {
    ContentView()
        .environment(SessionModel())
}
