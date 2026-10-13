import Foundation
import MacCastKit
import Observation
import RemoteCore
import SSHCore

extension SSHModel {
    func hasPasscode(for host: SSHHost) -> Bool {
        passcodes.hasPasscode(for: host.id)
    }

    /// One method, not a `save` plus a `setPasscode`: a server marked passcode-locked with nothing stored behind it has no way in.
    func save(_ host: SSHHost, passcode: String?) {
        Analytics.featureUsed(.sshHostSaved)
        var accepted = host
        if host.lock == .passcode {
            if let passcode {
                // The Keychain refused the write: falling back to unlocked is the lesser harm and not silent, as the row loses its badge.
                if !passcodes.set(passcode, for: host.id) { accepted.lock = .off }
            } else if !passcodes.hasPasscode(for: host.id) {
                accepted.lock = .off
            }
        }
        save(accepted)
    }

    /// The one door: the row, the log and a Shortcut all arrive here, since a gate on the row's tap is walked past by every other entrance. A second shell on a machine with one is exempt: the lock was already answered.
    func requestOpen(_ host: SSHHost) {
        // Reachable from the Sessions tab, while a shell, lock sheet or password prompt is drawn by the Servers screen; asking for the tab (as `openShellFromIntent(_:)` does) stops a log row seeming to do nothing.
        wantsFocus = true

        if let existing = openShells.first(where: { $0.host.id == host.id }) {
            selectedTerminalID = existing.id
            return
        }

        guard host.lock.isLocked else {
            connect(host)
            return
        }

        lockRejected = false
        lockedHost = host
    }

    /// Cancelling the system prompt is the user changing their mind, not a failed attempt, so the sheet is left exactly as it was.
    func unlockWithDevice(_ host: SSHHost) async {
        Analytics.featureUsed(.sshUnlocked)
        guard await DeviceAuthentication.unlock(reason: String(localized: "Open a shell on \(host.displayName).")) else { return }
        acceptUnlock(of: host)
    }

    func submit(passcode: String, for host: SSHHost) {
        guard SSHPasscodeStore.isValid(passcode) else { return }
        guard passcodes.verify(passcode, for: host.id) else {
            lockRejected = true
            return
        }
        acceptUnlock(of: host)
    }

    func cancelUnlock() {
        lockedHost = nil
        lockRejected = false
    }

    private func acceptUnlock(of host: SSHHost) {
        lockedHost = nil
        lockRejected = false
        connect(host)
    }
}
