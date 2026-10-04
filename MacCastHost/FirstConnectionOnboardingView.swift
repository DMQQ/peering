import AppKit
import RemoteCore
import SwiftUI

/// Third onboarding step: how to pair the first iPhone. Shown once, and left automatically the
/// moment a device actually connects, since that is the real finish line — "Skip for now" is
/// there only for someone who would rather come back to it later.
struct FirstConnectionOnboardingView: View {
    @Environment(HostModel.self) private var model
    let onContinue: () -> Void

    @State private var localAddress: String?

    var body: some View {
        ZStack {
            HostPalette.backdrop.ignoresSafeArea()
            HostPalette.stageLight.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 26) {
                    header

                    if model.pairing != nil || model.lastOutcome != nil {
                        livePairingCard
                    }

                    VStack(spacing: 0) {
                        row(
                            symbol: "wifi",
                            title: String(localized: "On the same network"),
                            detail: String(localized: "Open Peering on your iPhone. It finds this Mac by itself, and shows a code to confirm the first time.")
                        )
                        Divider().padding(.leading, 52)
                        row(
                            symbol: "number",
                            title: String(localized: "By address"),
                            detail: localAddress.map { String(localized: "If discovery is blocked where you are, enter \($0):\(model.boundPort) on your iPhone by hand.") }
                                ?? String(localized: "If discovery is blocked where you are, enter this Mac's address and port \(model.boundPort) by hand.")
                        )
                    }
                    .hostPanel()

                    remoteQRCard

                    Button("Skip for now", action: onContinue)
                        .controlSize(.regular)
                        .buttonStyle(.plain)
                        .foregroundStyle(HostPalette.faint)
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 36)
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 560, idealHeight: 680)
        .task { model.start() }
        .task { localAddress = localIPv4Address() }
        .onChange(of: model.connectedClients.isEmpty) { _, isEmpty in
            if !isEmpty { onContinue() }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 76, height: 76)
                .background(HostPalette.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(spacing: 8) {
                Text("Pair your first iPhone")
                    .font(HostDisplayFont.display(34))
                    .tracking(-1)
                    .multilineTextAlignment(.center)

                Label(model.status.isListening ? "Waiting for your iPhone" : "Starting…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.status.isListening ? HostPalette.success : HostPalette.muted)
            }
        }
    }

    /// The live handshake, drawn the moment a phone actually tries — the same code and QR
    /// `HostStatusView`'s own pairing card shows, so what appears here is the real thing rather
    /// than a preview of it.
    @ViewBuilder
    private var livePairingCard: some View {
        if let pairing = model.pairing {
            VStack(spacing: 14) {
                Text(pairing.isRemote
                     ? String(localized: "\(pairing.clientName) reached this Mac over the relay. Read the six digits out to whoever is holding it.")
                     : String(localized: "Scan this code with Peering, or enter the six digits on \(pairing.clientName)."))
                    .font(.callout)
                    .foregroundStyle(HostPalette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(formattedPairingCode(pairing.code))
                    .font(.system(size: 42, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .textSelection(.enabled)

                if let image = qrCodeImage(encoding: PairingPayload.encode(code: pairing.code)) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Pairing QR code")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
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
                Spacer(minLength: 0)
            }
            .padding(16)
            .hostPanel()
        }
    }

    /// A device that is not on this network reaches this Mac by its ID, and that ID is scannable
    /// from the first second hosting starts — not only once a phone has already found the Mac the
    /// other way. Skipped for an ID nothing has registered yet, the same guard `remotePairingSection`
    /// on Devices uses.
    @ViewBuilder
    private var remoteQRCard: some View {
        if PairingPayload.canonicalIdentifier(model.deviceID) != nil,
           let image = qrCodeImage(encoding: PairingPayload.encode(hostID: model.deviceID)) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("This Mac's device ID, as a QR code")

                VStack(alignment: .leading, spacing: 6) {
                    Text("From another network")
                        .font(.subheadline.weight(.medium))
                    Text("Not on this Wi-Fi? Scan this from Peering on your iPhone, or type the ID in by hand.")
                        .font(.caption)
                        .foregroundStyle(HostPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.deviceID)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Copy ID") {
                        let board = NSPasteboard.general
                        board.clearContents()
                        board.setString(model.deviceID, forType: .string)
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .hostPanel()
        }
    }

    private func row(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
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
}

#Preview {
    FirstConnectionOnboardingView(onContinue: {})
        .environment(HostModel())
}
