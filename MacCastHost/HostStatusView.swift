import RemoteCore
import SwiftUI

/// The host's window: whether it is reachable, whether it has permission to do its job,
/// and the pairing code when a client is asking to be trusted.
struct HostStatusView: View {
    @Environment(HostModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            permissionsSection
            Divider()
            pairingSection
            Divider()
            clientsSection
            Divider()
            eventLog
        }
        .padding(24)
        .frame(minWidth: 540, minHeight: 600, alignment: .leading)
        .task { model.start() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text("MacCast Host").font(.title.bold())
                Spacer()
                Text(statusText).foregroundStyle(.secondary).monospaced()
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("This Mac").foregroundStyle(.secondary)
                    Text(model.deviceName).monospaced()
                }
                GridRow {
                    Text("Bonjour").foregroundStyle(.secondary)
                    Text(ProtocolInfo.bonjourServiceType).monospaced()
                }
                GridRow {
                    Text("Protocol").foregroundStyle(.secondary)
                    Text("v\(String(ProtocolInfo.version))").monospaced()
                }
            }
            .font(.callout)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions").font(.headline)
            Text("Both of these fail silently, so they are checked here rather than discovered later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            permissionRow(
                title: "Accessibility",
                detail: "Required to send clicks and keystrokes to other apps.",
                granted: model.permissions.accessibilityGranted,
                request: model.permissions.requestAccessibility,
                openSettings: model.permissions.openAccessibilitySettings
            )
            permissionRow(
                title: "Screen Recording",
                detail: "Required to capture the screen. Without it the client sees black, with no error.",
                granted: model.permissions.screenRecordingGranted,
                request: model.permissions.requestScreenRecording,
                openSettings: model.permissions.openScreenRecordingSettings
            )

            HStack(alignment: .firstTextBaseline) {
                Button("Re-check") { model.refreshPermissions() }
                    .controlSize(.small)
                Text("Permissions are evaluated at launch — quit and reopen MacCast Host after changing them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Request", action: request).controlSize(.small)
                Button("Settings", action: openSettings).controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pairing").font(.headline)

            if let pairing = model.pairing {
                Text("\(pairing.clientName) wants to connect. Confirm these digits match the ones on that device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(formatted(pairing.code))
                    .font(.system(size: 46, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 4)

                Text("If they do not match, someone may be intercepting the connection — reject on the device.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let outcome = model.lastOutcome {
                Label(
                    outcome.accepted
                        ? "Paired with \(outcome.clientName)."
                        : "Pairing with \(outcome.clientName) was rejected.",
                    systemImage: outcome.accepted ? "checkmark.seal.fill" : "xmark.seal"
                )
                .foregroundStyle(outcome.accepted ? .green : .secondary)
            } else {
                Text("No pairing in progress. A new device will be asked to compare a six-digit code.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Trusted devices").font(.headline)
                Spacer()
                if !model.pairedClientIDs.isEmpty {
                    Button("Forget all", role: .destructive) { model.unpairAll() }
                        .controlSize(.small)
                }
            }

            if model.pairedClientIDs.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.pairedClientIDs, id: \.self) { id in
                    Text(id).font(.caption).monospaced().textSelection(.enabled)
                }
            }

            if !model.connectedClients.isEmpty {
                Text("Connected now: \(model.connectedClients.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.events.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .monospaced()
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch model.status {
        case .listening: .green
        case .starting: .yellow
        case .idle: .secondary
        case .failed: .red
        }
    }

    private var statusText: String {
        switch model.status {
        case .idle: "idle"
        case .starting: "starting…"
        case .listening(let port): "listening :\(port)"
        case .failed(let message): "error — \(message)"
        }
    }

    /// Grouped as `123 456`. Six unbroken digits are measurably harder to compare by eye,
    /// and comparing by eye is the entire security mechanism here.
    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }
}

#Preview {
    HostStatusView()
        .environment(HostModel())
}
