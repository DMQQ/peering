import AppKit
import RemoteCore
import SwiftUI

/// How a phone gets here, and the two permissions that let it.
extension HostStatusView {
    /// How a phone gets here — shown only while nothing is attached.
    ///
    /// The rest of this pane answers questions about a device that is already connected: what it
    /// is looking at, when it arrived, what it has been doing. Open the window on an idle Mac and
    /// every one of those is an answer to a question nobody has asked yet, which is what made
    /// this screen read as a single empty panel. This is the question to answer for a Mac that
    /// nobody has reached yet, and the only part of this pane that has anything to say then.
    ///
    /// It sits under the picture rather than above it. Instructions at the top of a window push
    /// the actual subject down out of sight, and this is a window whose subject arrives on its
    /// own — but the panel still reads second, which is where someone who is stuck will look.
    ///
    /// Withdrawn as soon as something connects, because then the answers below are the ones
    /// being looked for.
    @ViewBuilder
    var connectSection: some View {
        if model.connectedClients.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading(
                    "Connect",
                    detail: model.status.isListening
                        ? "This Mac is available on your network."
                        : "Press Start to make this Mac available."
                )

                VStack(spacing: 0) {
                    connectRow(
                        symbol: "wifi",
                        title: "On the same network",
                        detail: "Open Peering on your iPhone. It finds this Mac by itself, and shows a code to confirm the first time."
                    )
                    Divider().padding(.leading, 44)
                    connectRow(
                        symbol: "number",
                        title: "By address",
                        detail: "If discovery is blocked where you are, enter this Mac's address and port \(model.boundPort) by hand."
                    )
                    Divider().padding(.leading, 44)
                    connectRow(
                        symbol: "globe",
                        title: "From anywhere",
                        detail: "Once paired, this Mac stays reachable through the relay on any network. A first pairing can go that way too: use the device ID in Devices."
                    )
                }
                .hostPanel()
            }
        }
    }

    func connectRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Pairing

    @ViewBuilder
    var pairingSection: some View {
        if let pairing = model.pairing {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Pair a new iPhone", systemImage: "iphone.and.arrow.forward")
                        .font(.title3.weight(.semibold))

                    // Two sentences, because the two pairings ask for different things. On the
                    // network the phone can read the code itself, and the person here is the
                    // one confirming. Over the relay there is somebody else at the other end,
                    // and the only way the digits cross is that this person reads them out —
                    // so the card says which of the two situations it is looking at.
                    Text(pairing.isRemote
                         ? "This iPhone reached this Mac over the relay, so it is not on this network. Read the six digits out to whoever is holding it: they enter them on the iPhone, and the pairing only goes through if they match."
                         : "Scan this code with Peering, or enter the six digits on \(pairing.clientName).")
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
                }

                Spacer(minLength: 20)

                if let image = qrCode(encoding: PairingPayload.encode(code: pairing.code)) {
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
                        .foregroundStyle(HostPalette.muted)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Setup

    var permissionsSection: some View {
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
            .hostPanel()

            // Two buttons rather than one, because they do different things and only one of them
            // can help with Screen Recording. Accessibility is re-read on every check, so
            // "Check again" is the whole story there; Screen Recording is read once, when the
            // process starts, so a grant made while this window is open does nothing until the
            // app is opened again. The caption used to say "restart Peering" beside a button that
            // could not do it, which sent the user to the Dock to quit by hand.
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
