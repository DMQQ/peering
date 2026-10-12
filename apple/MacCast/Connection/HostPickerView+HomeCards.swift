import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit


extension HomeTab {
    var showsUnacknowledgedFailure: Bool {
        guard let message = model.failureMessage else { return false }
        return message != acknowledgedFailure
    }

    var failurePresentation: FailurePresentation {
        let detail = model.failureMessage ?? String(localized: "The connection could not be completed.")
        guard model.connectionPath == .relay else {
            return FailurePresentation(title: String(localized: "Could not connect"), message: detail, isRelayFailure: false)
        }

        let normalized = detail.lowercased()

        // A first pairing that found nothing: the relay answers the same whether the Mac is asleep or the ID was mistyped, and the ID is what the user can check.
        if let pairingID = model.remotePairingHostID,
           model.failureCause == .relayHostOffline {
            return FailurePresentation(
                title: String(localized: "No Mac answered"),
                message: String(localized: "Nothing is registered with the relay under \(pairingID). Check that the whole ID was copied or scanned from the Mac, and that the Mac is awake with Peering running."),
                isRelayFailure: false
            )
        }

        if model.failureCause == .relayHostOffline {
            return FailurePresentation(
                title: String(localized: "Mac is not available"),
                message: String(localized: "The relay is working, but this Mac is not connected to it. Make sure the Mac is awake and Peering is running there."),
                isRelayFailure: false
            )
        }

        // Matched on the word the sentence uses: `Failure.pinMismatch`'s sentence is the only thing that produces it.
        if normalized.contains("pinned") {
            return FailurePresentation(title: String(localized: "Mac identity changed"), message: detail, isRelayFailure: false)
        }

        if normalized.contains(String(localized: "a different mac answered")) {
            return FailurePresentation(title: String(localized: "Wrong Mac"), message: detail, isRelayFailure: false)
        }

        // The relay refuses a pair whose versions differ and states both numbers, so which side needs updating is worked out here, not assumed.
        if normalized.contains(String(localized: "host speaks v")) {
            let host = Self.version(in: normalized, after: String(localized: "host speaks v"))
            let client = Self.version(in: normalized, after: String(localized: "client speaks v"))
            if let host, let client, client < host {
                return FailurePresentation(
                    title: String(localized: "Update this device's app"),
                    message: String(localized: "The Mac is running a newer version of Peering than this app. Update Peering from the App Store, then connect again."),
                    isRelayFailure: false
                )
            }
            return FailurePresentation(
                title: String(localized: "Update Peering on the Mac"),
                message: String(localized: "The Mac is running an older version of Peering than this app. Update it there, then pair again."),
                isRelayFailure: false
            )
        }

        return FailurePresentation(
            title: String(localized: "Remote connection unavailable"),
            message: String(localized: "Peering could not complete the connection through the relay. Your Mac may be working normally. If both devices are nearby, put them on the same network and connect from Nearby.\n\nDetail: \(detail)"),
            isRelayFailure: true
        )
    }

    // MARK: Cards

    var connectionFailureCard: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 5) {
                Text(failurePresentation.title)
                    .font(.subheadline.weight(.semibold))
                Text(failurePresentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if failurePresentation.isRelayFailure {
                    Button("Search nearby") { model.restartBrowsing() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
            Button {
                acknowledgedFailure = model.failureMessage
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .cardSurface()
    }

    var connectionsSection: some View {
        VStack(spacing: 0) {
            // Anchored after the padding so the highlight rings the block the eye sees, not the text inside.
            nearbyCardContent
                .padding(16)
                .tourAnchor(.connectNearby)
            Divider()
                .overlay(Color.white.opacity(0.1))
            remotePairingEntry
                .padding(16)
                .tourAnchor(.connectRemote)
            Divider()
                .overlay(Color.white.opacity(0.1))
            pairedCardContent
                .padding(16)
                .tourAnchor(.connectTrusted)
        }
        .cardBackground()
    }

    var nearbyCardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                sectionLabel(String(localized: "Nearby"), systemImage: "dot.radiowaves.left.and.right")
                if model.hosts.isEmpty {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(.secondary)
                }
                Spacer()

                Button { showsManualConnection = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "network")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Connect by address")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ColorPalette.surface, in: Capsule())
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(RailButtonStyle())

                Button { model.restartBrowsing() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(ColorPalette.surface, in: Circle())
                }
                .buttonStyle(RailButtonStyle())
                .accessibilityLabel("Search again")
            }

            // The line is drawn in both states rather than inside each: as branches it was a different view either side of the first Mac arriving, and the sentences cross-faded.
            if !model.hosts.isEmpty {
                VStack(spacing: 8) {
                    ForEach(model.hosts) { host in
                        Button {
                            model.connect(to: .discovered(host))
                        } label: {
                            hostRow(host)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy || !isCompatible(host))
                        .transition(Self.hostArrival)
                    }
                }
            }

            if model.localNetworkDenied { LocalNetworkNotice() }

            Text(model.browseStatus)
                .font(.caption)
                .foregroundStyle(model.hosts.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .padding(.vertical, model.hosts.isEmpty ? 4 : 0)
        }
        // On the container, not each row: a transition cannot move a neighbour.
        .animation(reduceMotion ? nil : Motion.settle, value: model.hosts)
    }

    /// A fade and eight points of rise: `.move` would read as a list being rearranged rather than a name appearing.
    private static let hostArrival = AnyTransition.modifier(
        active: HostArrival(progress: 0),
        identity: HostArrival(progress: 1)
    )

    var remotePairingEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel(String(localized: "Another network"), systemImage: "globe")

            Button {
                showsRemotePairing = true
            } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: "number")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pair with a Mac elsewhere")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorPalette.ink)
                            .multilineTextAlignment(.leading)
                        Text("Type or scan the device ID shown on it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .rowSurface()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .opacity(model.isBusy ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var pairedCardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel(String(localized: "Trusted Macs"), systemImage: "checkmark.shield")

            if model.pairedHostIDs.isEmpty {
                HStack(spacing: 12) {
                    IconTile(symbol: "shield")
                    Text("A Mac appears here after your first secure pairing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.pairedHostIDs, id: \.self) { hostID in
                        pairedRow(hostID)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var firstPairingCard: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "wifi")

            VStack(alignment: .leading, spacing: 4) {
                Text("First connection")
                    .font(.subheadline.weight(.semibold))
                Text("On the same network, choose your Mac from Nearby. If it is somewhere else, pair with the device ID from Devices in Peering on the Mac. Someone has to be at the Mac either way: it shows six digits and you enter them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The Mac app is a download, so someone who has just installed this half has no other way to find it. Drawn like the app's other secondary actions: the only accent hue is "this is on", and a link in it would borrow a state to mean tap me. See ``ColorPalette``.
                Link(destination: PeeringSite.download) {
                    Label("Get Peering for Mac", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .cardSurface()
    }

    var securityCard: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "faceid")

            VStack(alignment: .leading, spacing: 3) {
                Text("Protect paired Macs")
                    .font(.subheadline.weight(.semibold))
                Text("Ask for \(DeviceAuthentication.biometryName), or your device passcode, when Peering is opened again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { requiresBiometricUnlock },
                set: { requested in
                    guard requested else {
                        requiresBiometricUnlock = false
                        return
                    }
                    Task {
                        if await DeviceAuthentication.authenticate(
                            reason: String(localized: "Protect access to your paired Macs.")
                        ) {
                            requiresBiometricUnlock = true
                        }
                    }
                }
            ))
            .labelsHidden()
            .disabled(!DeviceAuthentication.isAvailable)
        }
        .cardSurface()
    }

    // MARK: Tips

    /// Tips wait for the screen to finish arriving: the frames a tour reads are those of the real views, and a ring measured off a card still in motion rings where the card used to be. An array because a screen with several tours (see ``SSHTerminalScreen``) orders them.
    var dueConnectTours: [Tour] {
        guard !hasSeenTourConnect, sectionsVisible else { return [] }
        return [.connect]
    }

}

// MARK: - Supporting types

private struct HostArrival: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .offset(y: (1 - progress) * 8)
    }
}

struct FailurePresentation {
    let title: String
    let message: String
    let isRelayFailure: Bool
}
