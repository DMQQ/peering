import MacCastKit
import RemoteCore
import SwiftUI

extension SessionModel {
    /// The Mac keeps its half, so the next connection is refused by it until unpaired there too: the honest behaviour for "forget".
    func forget(hostID: String) {
        Analytics.featureUsed(.macForgotten)
        pins.remove(hostID: hostID)
        pairedHostIDs = pins.hostIDs
        publishKnownMacs()
        append(note: String(localized: "Forgot \(hostID). Unpair this device on the Mac as well."))
    }

    // A `resetDeviceIdentity()` belongs here only alongside a quota the relay cannot reset per client ID: it would hand out a fresh allowance per tap.

    func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        device.saveName(trimmed)
        device = DeviceIdentity.loadOrCreate(defaultName: trimmed)
    }
}

extension SessionModel {
    /// A Mac's own QR code, scanned with the system camera. A Mac on this network is dialled directly, because the relay is for a Mac that cannot be reached any other way and costs the free allowance; only a Mac that is not here goes through it.
    func openHostLink(hostID: String) {
        if pairedHostIDs.contains(hostID) {
            connectToTrusted(hostID: hostID)
        } else if let host = hosts.first(where: { $0.id == hostID }) {
            connect(to: .discovered(host))
        } else {
            pairWithRemoteMac(hostID: hostID)
        }
    }

    /// The one path into a Mac with no pin behind it: the user has just read a device ID off the other machine. The guard is answered, not relaxed: the Mac still asks both people to compare six digits.
    @discardableResult
    func pairWithRemoteMac(hostID text: String) -> PairingPayloadError? {
        Analytics.featureUsed(.remotePairingStarted)
        let hostID: String
        do {
            hostID = try PairingPayload.hostID(from: text)
        } catch let problem as PairingPayloadError {
            Analytics.pairingInputRefused(problem, stage: .codeEntry)
            return problem
        } catch {
            // Unreachable: `PairingPayload` reports every refusal as its own case.
            return .notAnIdentifier(text)
        }

        guard allowsRelay else {
            // A setting the user turned off, said here too because this path cannot work without it.
            append(note: String(localized: "Remote access is turned off in Settings, so a Mac on another network cannot be reached."))
            return nil
        }

        connect(to: relayPairingTarget(hostID: hostID, name: String(localized: "A Mac")))
        return nil
    }

    func confirmPairing(accepted: Bool, secret: Data? = nil) {
        // Declining ends the session from the Mac's side too and arrives as `.disconnected`, so without this the user's own "no" reads as a lost connection.
        if !accepted { activeSession?.userEndedDeliberately = true }
        Analytics.pairingDecided(accepted: accepted)
        if !accepted { Analytics.pairingFailed(stage: .confirm, reason: .cancelled) }
        PostHogLog.info("pairing decision submitted", attributes: [
            "pairing_outcome": accepted ? "accepted" : "declined",
        ])
        session?.confirmPairing(accepted: accepted, secret: secret)
    }
}
