import PeeringKit
import MessageUI
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

extension SettingsTab {
    var remoteAccessSection: some View {
        Controls.card(
            String(localized: "Remote access"),
            footer: model.phase == .ready
                ? String(localized: "Relay connects across networks. Privacy mode dims the Mac's displays without stopping the stream.")
                : String(localized: "Relay connects across networks.")
        ) {
            Controls.toggle(String(localized: "Allow relay connections"), systemImage: "network", isOn: $allowsRelay)
            // Per session: the Mac is only told while one is live, and it is undone on disconnect.
            if model.phase == .ready {
                Controls.divider
                Controls.toggle(String(localized: "Privacy mode"), systemImage: "moon.fill", isOn: Binding(
                    get: { model.privacyModeEnabled },
                    set: { model.setPrivacyMode($0) }
                ))
            }

            // The subscription's door for everybody else: the paywall was otherwise reachable only by the relay refusing for quota. Hidden only once the plan is unlimited, not for anyone who has bought something, so a metered subscriber can still climb the ladder.
            if !model.storeManager.relayPlan.isUnlimited {
                Controls.divider
                Button { model.paywallReason = .upgrade } label: {
                    Controls.row(String(localized: "Upgrade to Pro"), systemImage: "sparkles") {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(RailButtonStyle(scale: 0.99))
            }
        }
    }

    var securitySection: some View {
        Controls.card(
            String(localized: "Security and privacy"),
            footer: String(localized: "Usage statistics are anonymous counts of app opens and sessions, with the app version and your plan. Never your screen, files, keystrokes or Macs.")
        ) {
            Controls.toggle(String(localized: "Require \(DeviceAuthentication.biometryName) on open"), systemImage: DeviceAuthentication.biometrySymbol, isOn: Binding(
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
            .disabled(!DeviceAuthentication.isAvailable)
            Controls.divider
            Controls.toggle(String(localized: "Share anonymous usage statistics"), systemImage: "chart.bar", isOn: $analyticsEnabled)
                .onChange(of: analyticsEnabled) { _, enabled in PostHogConfiguration.setEnabled(enabled) }
        }
    }

    var trustedMacsSection: some View {
        Controls.card(String(localized: "Trusted Macs")) {
            ForEach(Array(model.pairedHostIDs.enumerated()), id: \.element) { index, hostID in
                Controls.row(model.displayName(forHostID: hostID) ?? hostID, systemImage: "macbook") {
                    Button("Forget", role: .destructive) { model.forget(hostID: hostID) }
                        .font(.subheadline)
                        .foregroundStyle(ColorPalette.danger)
                }
                if index < model.pairedHostIDs.count - 1 { Controls.divider }
            }
        }
    }

    var damagedPairingsSection: some View {
        Controls.card(
            String(localized: "Paired Macs"),
            footer: String(localized: "The pairings saved on this iPhone are damaged and cannot be read. Reset them to pair your Macs again. No new pairing is saved until then.")
        ) {
            Controls.row(String(localized: "Damaged pairings"), systemImage: "exclamationmark.triangle") {
                ResetPairedMacsButton(model: model)
                    .font(.subheadline)
                    .foregroundStyle(ColorPalette.danger)
            }
        }
    }

    var identitySection: some View {
        Controls.card(
            String(localized: "Device identity"),
            footer: String(localized: "How Macs recognise this device. Created once, on first launch.")
        ) {
            Controls.row(String(localized: "Device ID"), systemImage: "number") {
                Text(model.device.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Controls.divider

            Controls.row(String(localized: "Private key"), systemImage: "key.fill") {
                Text("P-256 · in Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Controls.divider

            Controls.row(String(localized: "Paired Macs"), systemImage: "macbook") {
                Text("\(model.pairedHostIDs.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
