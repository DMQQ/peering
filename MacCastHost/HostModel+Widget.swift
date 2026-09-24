import Foundation
import WidgetKit

// MARK: - Desktop widget

extension HostModel {
    static let widgetSuiteName = "group.pl.dmq.peering"

    /// Publishes the small amount of host state a WidgetKit extension can read.
    func publishHostWidgetState(listening override: Bool? = nil) {
        guard let defaults = UserDefaults(suiteName: Self.widgetSuiteName) else { return }
        defaults.set(override ?? status.isListening, forKey: "hostWidget.isListening")
        defaults.set(deviceName.isEmpty ? Self.defaultDeviceName : deviceName, forKey: "hostWidget.deviceName")
        defaults.set(connectedClients.map(\.name), forKey: "hostWidget.connectedNames")
        WidgetCenter.shared.reloadTimelines(ofKind: "PeeringHostControl")
    }

    /// Handles Start and Stop links from the macOS desktop widget.
    func handleWidgetCommand(_ url: URL) {
        guard url.scheme == "peering-host" else { return }
        switch url.host {
        case "start":
            start()
        case "stop":
            // On a cold launch the window's task also calls start. Let that idempotent launch
            // path settle before applying the explicit Stop command from the widget.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                self?.stop()
            }
        default:
            break
        }
    }
}
