import AppKit
import SwiftUI

/// The menu bar icon: whether a device is attached, and nothing else.
///
/// The host is a background agent, so this question is asked with the window shut — which is
/// almost always. The window is where the host is set up; this is where it is glanced at.
///
/// The two states differ by *shape*, not colour: macOS draws a menu bar extra as a template
/// image, so a tint would be discarded and "connected" would look exactly like "not".
struct HostMenuBarLabel: View {
    let connected: Bool

    var body: some View {
        Image(systemName: connected ? "iphone" : "iphone.slash")
            .accessibilityLabel(connected ? "A device is connected" : "No device connected")
    }
}

/// The menu itself. Built when it is opened, so the elapsed times are current to the second
/// the user looked rather than to whenever the model last changed.
struct HostMenuBarContent: View {
    @Environment(HostModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.connectedClients.isEmpty {
            Text(model.status.isListening ? "Waiting for a device" : "Not hosting")
        } else {
            ForEach(model.connectedClients) { client in
                Text("\(client.name) · \(client.elapsedDescription())")
            }
        }

        Divider()

        Button(model.status.isListening ? "Stop hosting" : "Start hosting") {
            model.status.isListening ? model.stop() : model.start()
        }

        Button("Open Peering") {
            openWindow(id: MacCastHostApp.mainWindowID)
            // The window may open behind whatever has focus; a menu bar item that appears to do
            // nothing is worse than one that is missing.
            NSApp.activate()
        }

        Divider()

        Button("Quit Peering") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
