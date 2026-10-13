import SSHCore
import SwiftUI

/// Both lock kinds share one sheet, as they are one question asked two ways; two sheets would be two places to keep the name, cancel and refusal wording in step.
struct SSHLockSheet: View {
    @Environment(SSHModel.self) private var model
    let host: SSHHost

    @State private var passcode = ""
    @State private var isAskingDevice = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.displayName)
                        .font(.headline)
                    Text(host.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                if host.lock == .passcode {
                    passcodeEntry
                } else {
                    deviceEntry
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .background(ColorPalette.backdrop)
            .navigationTitle("Locked")
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar(onCancel: { model.cancelUnlock() })
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(host.lock == .passcode ? 400 : 280)])
        // Asked as the sheet comes up: the tap on the server is the request. A cancelled prompt leaves the button for a second attempt.
        .task {
            if host.lock == .biometrics { await askDevice() }
        }
    }

    // MARK: - The passcode

    private var passcodeEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            PasscodeDots(
                filled: passcode.count,
                total: SSHPasscodeStore.length,
                isRejected: model.lockRejected
            )

            Text(model.lockRejected
                 ? "That passcode is not right for this server."
                 : "The passcode you set for this server, not the one for your iPhone.")
                .font(.caption)
                .foregroundStyle(model.lockRejected ? ColorPalette.danger : .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)

            PasscodePad(
                onDigit: { digit in
                    guard passcode.count < SSHPasscodeStore.length else { return }
                    passcode.append(String(digit))
                    if passcode.count == SSHPasscodeStore.length { submit() }
                },
                onDelete: {
                    guard !passcode.isEmpty else { return }
                    passcode.removeLast()
                }
            )
        }
    }

    private func submit() {
        let typed = passcode
        model.submit(passcode: typed, for: host)
        // Still up means the passcode was wrong; cleared so the next attempt does not start by deleting the last.
        if model.lockedHost != nil { passcode = "" }
    }

    // MARK: - The device's own answer

    private var deviceEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await askDevice() }
            } label: {
                Label(
                    String(localized: "Unlock with \(DeviceAuthentication.biometryName)"),
                    systemImage: DeviceAuthentication.biometrySymbol
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(ColorPalette.accent)
            .foregroundStyle(.white)
            .disabled(isAskingDevice || !DeviceAuthentication.canLockServers)

            // A lock nobody can answer is worse than none: reached when the device passcode was removed since the lock was set, and every tap would open a sheet with a dead button.
            Text(DeviceAuthentication.canLockServers
                 ? "This server is locked to the owner of this device."
                 : "This iPhone has no passcode set, so there is no way to answer this server's lock. Set one in Settings, or turn the lock off for this server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func askDevice() async {
        guard !isAskingDevice else { return }
        isAskingDevice = true
        await model.unlockWithDevice(host)
        isAskingDevice = false
    }
}
