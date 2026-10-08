import Foundation
import AppKit
import WidgetKit

// MARK: - Desktop widget

extension HostModel {
    static let widgetSuiteName = "group.pl.dmq.peering"

    func publishHostWidgetState(listening override: Bool? = nil) {
        guard let defaults = UserDefaults(suiteName: Self.widgetSuiteName) else { return }
        defaults.set(override ?? status.isListening, forKey: "hostWidget.isListening")
        defaults.set(deviceName.isEmpty ? Self.defaultDeviceName : deviceName, forKey: "hostWidget.deviceName")
        defaults.set(connectedClients.map(\.name), forKey: "hostWidget.connectedNames")
        WidgetCenter.shared.reloadTimelines(ofKind: "PeeringHostControl")
    }

    func handleWidgetCommand(_ url: URL) {
        guard url.scheme == "peering-host" else { return }
        switch url.host {
        case "start":
            start()
        case "stop":
            // Any web page or app can open this URL, so stopping while someone is connected is confirmed.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard let self, connectedClients.isEmpty || confirmStopWhileConnected() else { return }
                stop()
            }
        default:
            break
        }
    }
}

extension HostModel {
    func confirmStopWhileConnected() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Stop sharing this Mac?")
        alert.informativeText = String(localized: "A connected device will be disconnected.")
        alert.addButton(withTitle: String(localized: "Stop"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
