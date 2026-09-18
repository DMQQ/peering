import SSHCore
import SwiftUI

/// The gate a locked server puts up before its shell opens.
///
/// Both kinds of lock share one sheet, because they are one question — "is this you" — asked in
/// whichever of the two ways the user chose when they set it. Two sheets would be two places to
/// keep the server's name, the cancel button and the wording of a refusal in step.
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelUnlock() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(host.lock == .passcode ? 400 : 280)])
        // Asked for as the sheet comes up rather than waiting on a tap: the user tapped a server
        // and this is the lock they put on it, so the tap *is* the request. A cancelled system
        // prompt leaves the sheet and its button exactly where they were, and the button is there
        // for the second attempt.
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
        // Still up means the passcode was wrong. Cleared rather than left in place: leaving six
        // digits in a rejected pad makes the next attempt start by deleting somebody else's answer.
        if model.lockedHost != nil { passcode = "" }
    }

    // MARK: - The device's own answer

    private var deviceEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await askDevice() }
            } label: {
                Label(
                    "Unlock with \(DeviceAuthentication.biometryName)",
                    systemImage: DeviceAuthentication.biometrySymbol
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(ColorPalette.accent)
            .foregroundStyle(.white)
            .disabled(isAskingDevice || !DeviceAuthentication.canLockServers)

            // A lock nobody can answer is worse than no lock: the server would still be in the
            // list, and every tap on it would open a sheet with a dead button and no explanation.
            // Reached when the device's passcode has been removed since the lock was set.
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
