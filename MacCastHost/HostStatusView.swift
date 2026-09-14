import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import RemoteCore
import SwiftUI

/// The host's window: whether it is reachable, whether it has permission to do its job,
/// and the pairing code when a client is asking to be trusted.
struct HostStatusView: View {
    @Environment(HostModel.self) private var model

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    statusHeader
                    Divider().opacity(0.7)

                    VStack(alignment: .leading, spacing: 24) {
                        if model.pairing != nil || model.lastOutcome != nil {
                            pairingSection
                        }

                        HStack(alignment: .top, spacing: 32) {
                            VStack(alignment: .leading, spacing: 28) {
                                permissionsSection
                                trustedDevicesSection
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                            activitySection
                                .frame(width: 280, alignment: .topLeading)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 26)
                    .padding(.bottom, 30)
                }
            }
        }
        .tint(HostPalette.ink)
        .frame(minWidth: 720, minHeight: 620, alignment: .topLeading)
        .task { model.start() }
    }

    // MARK: - Status

    private var statusHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(statusColor.opacity(0.13))
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("Peering")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .tracking(-0.5)

                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).foregroundStyle(.secondary)
                    if let client = connectedClient {
                        Text("· \(client.elapsedDescription())")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .font(.callout)
            }

            Spacer(minLength: 24)

            VStack(alignment: .trailing, spacing: 3) {
                Text(model.deviceName)
                    .font(.subheadline.weight(.medium))
                Text("Local network · port \(ProtocolInfo.defaultPort)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button(model.status.isListening ? "Stop" : "Start") {
                model.status.isListening ? model.stop() : model.start()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    // MARK: - Pairing

    @ViewBuilder
    private var pairingSection: some View {
        if let pairing = model.pairing {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Pair a new iPhone", systemImage: "iphone.and.arrow.forward")
                        .font(.title3.weight(.semibold))

                    Text("Scan this code with Peering, or enter the six digits on \(pairing.clientName).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(formatted(pairing.code))
                        .font(.system(size: 42, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .textSelection(.enabled)

                    Label("Only pair a device you recognize.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 20)

                if let image = qrCode(for: pairing.code) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 126, height: 126)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Pairing QR code")
                }
            }
            .priorityPanel()
        } else if let outcome = model.lastOutcome {
            HStack(spacing: 12) {
                Image(systemName: outcome.accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(outcome.accepted ? HostPalette.ink : HostPalette.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.accepted ? "Device paired" : "Pairing cancelled")
                        .font(.headline)
                    Text(outcome.accepted
                         ? "\(outcome.clientName) can now reconnect automatically."
                         : "\(outcome.clientName) was not added to trusted devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Setup

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Mac access", detail: "Peering needs both permissions to stream and control this Mac.")

            VStack(spacing: 0) {
                permissionRow(
                    title: "Accessibility",
                    detail: "Clicks and keyboard input",
                    icon: "cursorarrow.click.2",
                    granted: model.permissions.accessibilityGranted,
                    request: model.permissions.requestAccessibility,
                    openSettings: model.permissions.openAccessibilitySettings
                )
                Divider().padding(.leading, 42)
                permissionRow(
                    title: "Screen Recording",
                    detail: "Live picture on your iPhone",
                    icon: "rectangle.dashed.badge.record",
                    granted: model.permissions.screenRecordingGranted,
                    request: model.permissions.requestScreenRecording,
                    openSettings: model.permissions.openScreenRecordingSettings
                )
            }
            .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                Button("Check again") { model.refreshPermissions() }
                    .controlSize(.small)
                Text("Restart Peering after changing a permission.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        icon: String,
        granted: Bool,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(granted ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HostPalette.ink)
            } else {
                Button("Allow", action: request).controlSize(.small)
                Button("Settings", action: openSettings).controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Devices and activity

    private var trustedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading("Trusted devices", detail: "Reconnect without pairing again.")
                Spacer()
                if !model.pairedClientIDs.isEmpty {
                    Button("Forget all", role: .destructive) { model.unpairAll() }
                        .controlSize(.small)
                }
            }

            if model.pairedClientIDs.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.slash")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No iPhones paired yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.pairedClientIDs.enumerated()), id: \.element) { index, id in
                        if index > 0 { Divider().padding(.leading, 42) }
                        deviceRow(id)
                    }
                }
                .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func deviceRow(_ id: String) -> some View {
        let connected = model.isConnected(id)
        return HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(connected ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(id)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(connected ? "Connected now" : "Trusted")
                    .font(.caption)
                    .foregroundStyle(connected ? HostPalette.ink : HostPalette.muted)
            }
            Spacer()
            Circle()
                .fill(connected ? HostPalette.ink : HostPalette.faint.opacity(0.5))
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Activity", detail: "Recent host events")

            if model.events.isEmpty {
                Text("Waiting for a connection…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                    .padding(14)
                    .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.events.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                }
                .frame(minHeight: 190, maxHeight: 300)
                .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Text("Protocol v\(ProtocolInfo.version)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    /// Connected outranks listening: "is anyone there" is the question this window is answering,
    /// and "Ready for iPhone" is true whether or not a client is attached — which is why it was
    /// the wrong thing to say while one was.
    private var statusColor: Color {
        if !model.connectedClients.isEmpty { return HostPalette.ink }
        switch model.status {
        case .listening: return HostPalette.muted
        case .starting: return HostPalette.faint
        case .idle: return HostPalette.faint
        case .failed: return HostPalette.ink
        }
    }

    private var statusText: String {
        if let client = model.connectedClients.first {
            let others = model.connectedClients.count - 1
            return others > 0 ? "Connected — \(client.name) +\(others)" : "Connected — \(client.name)"
        }
        switch model.status {
        case .idle: return "Not hosting"
        case .starting: return "Starting…"
        case .listening: return "Waiting for a device"
        case .failed(let message): return "Error — \(message)"
        }
    }

    /// The longest-attached device, or nil when none is.
    ///
    /// With more than one client attached the oldest is the session — it is the one that has
    /// been waiting to be noticed for longest.
    private var connectedClient: ConnectedClient? {
        model.connectedClients.min { $0.since < $1.since }
    }

    /// Grouped as `123 456`. Six unbroken digits are harder to compare by eye.
    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }

    private func qrCode(for code: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("peering://pair?code=\(code)".utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 9, y: 9)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private extension View {
    func priorityPanel() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HostPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.22))
            }
    }
}

#Preview {
    HostStatusView()
        .environment(HostModel())
}
