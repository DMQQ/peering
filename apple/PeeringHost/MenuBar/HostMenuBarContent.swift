import AppKit
import PeeringKit
import RemoteCore
import SwiftUI

struct HostMenuBarContent: View {
    @Environment(HostModel.self) var model
    @Environment(Updater.self) var updater
    @Environment(\.dismissMenuBar) var dismissMenuBar

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let version = updater.availableVersion {
                updateRow(version)
            }

            if !model.permissions.allRequiredGranted {
                setupCard
            } else {
                if !model.connectedClients.isEmpty {
                    devicesCard
                }
                awakeCard
                resourcesRow
            }

            footer
        }
        .padding(14)
        .frame(width: 320)
        .animation(HostMotion.state, value: model.connectedClients.count)
        .animation(HostMotion.state, value: updater.availableVersion)
    }
}
