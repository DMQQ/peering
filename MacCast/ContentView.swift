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
            if remote {
                // Unlock — just update the mask; no geometry request needed. iOS will use
                // the device's current orientation on the next layout pass. Sending an active
                // requestGeometryUpdate(.allButUpsideDown) while in portrait would tell iOS
                // "portrait is fine" and it would stay locked there.
                OrientationLock.shared.allowed = .allButUpsideDown
            } else {
                // Landing screen: actively snap back to portrait.
                OrientationLock.shared.allowed = .portrait
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(SessionModel())
}
