import RemoteCore
import SwiftUI

/// The root. Two screens, and which one is showing is a direct function of the session phase —
/// there is no separate "am I connected" flag that could disagree with the phase.
struct ContentView: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .ready, .confirming:
                // The pairing prompt is drawn by `RemoteScreen`, so the canvas is already
                // behind it — the user compares the code against a Mac that is visibly there.
                RemoteScreen()
            default:
                HostPickerView()
            }
        }
        .animation(.default, value: model.phase)
    }
}

#Preview {
    ContentView()
        .environment(SessionModel())
}
