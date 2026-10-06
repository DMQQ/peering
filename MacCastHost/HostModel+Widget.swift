import Foundation
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
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                self?.stop()
            }
        default:
            break
        }
    }
}
