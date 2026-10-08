import AppKit
import RemoteCore
import SwiftUI

extension HostStatusView {
    @ViewBuilder
    var connectSection: some View {
        if model.connectedClients.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading(
                    String(localized: "Connect"),
                    detail: model.status.isListening
                        ? String(localized: "This Mac is available on your network.")
                        : String(localized: "Press Start to make this Mac available.")
                )

                HStack(alignment: .top, spacing: 12) {
                    connectRow(
                        symbol: "wifi",
                        title: String(localized: "On the same network"),
                        detail: String(localized: "Open Peering on your iPhone. It finds this Mac by itself, and shows a code to confirm the first time.")
                    )
                    connectRow(
                        symbol: "number",
                        title: String(localized: "By address"),
                        detail: String(localized: "If discovery is blocked where you are, enter this Mac's address and port \(String(model.boundPort)) by hand.")
                    )
                    connectRow(
                        symbol: "qrcode",
                        title: String(localized: "From anywhere"),
                        detail: String(localized: "Scan the code in the sidebar with Peering. Once paired, this Mac stays reachable through the relay on any network.")
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func connectRow(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 32, height: 32)
                .background(HostPalette.raised, in: Circle())
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .hostCaption()
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: HostPalette.panelRadius, style: .continuous)
                .strokeBorder(HostPalette.litEdge, lineWidth: 1)
        )
    }

    @ViewBuilder
    var pairingSection: some View {
        if let pairing = model.pairing {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Pair a new iPhone", systemImage: "iphone.and.arrow.forward")
                        .font(.title3.weight(.semibold))

                    // Two sentences: on the network the phone reads the code and this person confirms; over the relay this person reads the digits out.
                    Text(pairing.isRemote
                         ? "This iPhone reached this Mac over the relay, so it is not on this network. Read the six digits out to whoever is holding it: they enter them on the iPhone, and the pairing only goes through if they match."
                         : String(localized: "Scan this code with Peering, or enter the six digits on \(pairing.clientName)."))
                        .font(.callout)
                        .foregroundStyle(HostPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(formatted(pairing.code))
                        .font(.system(size: 42, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .textSelection(.enabled)

                    Label(pairing.isRemote
                          ? "Only read these digits to someone you are expecting."
                          : "Only pair a device you recognize.",
                          systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(HostPalette.muted)

                    if pairing.needsApproval {
                        PairingApprovalButtons(clientName: pairing.clientName) { model.resolvePairing(approved: $0) }
                    }
                }

                Spacer(minLength: 20)

                if let image = qrCode(encoding: PairingPayload.encode(code: pairing.code, secret: pairing.secret)) {
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
                         ? String(localized: "\(outcome.clientName) can now reconnect automatically.")
                         : String(localized: "\(outcome.clientName) was not added to trusted devices."))
                        .font(.caption)
                        .foregroundStyle(HostPalette.muted)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Setup

    var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(String(localized: "Mac access"), detail: String(localized: "Peering needs both permissions to stream and control this Mac."))

            VStack(spacing: 0) {
                permissionRow(
                    title: String(localized: "Accessibility"),
                    detail: String(localized: "Clicks and keyboard input"),
                    icon: "cursorarrow.click.2",
                    granted: model.permissions.accessibilityGranted,
                    request: model.permissions.requestAccessibility,
                    openSettings: model.permissions.openAccessibilitySettings
                )
                Divider().padding(.leading, 42)
                permissionRow(
                    title: String(localized: "Screen Recording"),
                    detail: String(localized: "Live picture on your iPhone"),
                    icon: "rectangle.dashed.badge.record",
                    granted: model.permissions.screenRecordingGranted,
                    request: model.permissions.requestScreenRecording,
                    openSettings: model.permissions.openScreenRecordingSettings
                )
            }
            .hostPanel()

            // Screen Recording is read once at process start, so a grant made while open needs a relaunch; Accessibility is re-read on every check.
            HStack(spacing: 8) {
                Button("Check again") { model.refreshPermissions() }
                    .controlSize(.small)
                if !model.permissions.screenRecordingGranted {
                    Button("Relaunch Peering") { model.permissions.relaunch() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                Text(model.permissions.screenRecordingGranted
                     ? "Accessibility is picked up straight away. Screen Recording needs a relaunch."
                     : "Screen Recording is only read when the app starts, so it needs a relaunch to take effect.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func permissionRow(
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
                Text(detail).font(.caption).foregroundStyle(HostPalette.muted)
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

    // MARK: - Settings

}
