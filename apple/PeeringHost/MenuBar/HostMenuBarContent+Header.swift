import AppKit
import PeeringKit
import RemoteCore
import SwiftUI

extension HostMenuBarContent {
    var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Peering")
                    .font(HostDisplayFont.display(17))
                    .tracking(-0.4)
                    .foregroundStyle(Color.primary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: statusColor.opacity(0.7), radius: 3)
                    Text(statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if model.permissions.allRequiredGranted {
                powerButton
            }
        }
    }

    private var powerButton: some View {
        let on = model.status.isListening
        return Button {
            on ? model.stop() : model.start()
        } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(on ? Color.white : Color.secondary)
                .frame(width: 28, height: 28)
                .background(on ? AnyShapeStyle(Color.accentColor.opacity(0.9)) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Circle())
                .overlay(Circle().strokeBorder(on ? .clear : Color.primary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(on ? "Stop hosting" : "Start hosting")
        .accessibilityLabel(on ? "Stop hosting" : "Start hosting")
    }

    private var statusColor: Color {
        if !model.permissions.allRequiredGranted { return Color.orange }
        if !model.connectedClients.isEmpty { return Color.green }
        switch model.status {
        case .listening: return Color.accentColor
        case .starting, .idle: return Color.secondary.opacity(0.75)
        case .failed: return Color.red
        }
    }

    private var statusText: String {
        if !model.permissions.allRequiredGranted { return String(localized: "Setup required") }
        if !model.connectedClients.isEmpty {
            let count = model.connectedClients.count
            return count == 1 ? String(localized: "Streaming to 1 device") : String(localized: "Streaming to \(count) devices")
        }
        switch model.status {
        case .idle: return String(localized: "Not hosting")
        case .starting: return String(localized: "Starting…")
        case .listening: return String(localized: "Waiting for a device")
        case .failed(let message): return String(localized: message)
        }
    }
}
