import Foundation
import RemoteCore

/// The sentence for a failure in the user's language. RemoteCore's own sentences are English and are for the log; a failure with no cause keeps the sentence it came with.
enum FailureText {
    static func message(for cause: ClientSession.FailureCause) -> String {
        switch cause {
        case .sessionBusy:
            return String(localized: "This session is already connecting or connected.")
        case .anotherDeviceConnected:
            return String(localized: "Another phone is using this Mac. Wait for it to finish, or take over if it is yours.")
        case .handshakeTimedOut:
            return String(localized: "The Mac connected but did not finish setting up the session. Check that it is awake and try again.")
        case .handshakeUnreadable:
            return String(localized: "The Mac sent something this app could not read. Update Peering on both devices and try again.")
        case .pinsUnreadable:
            return String(localized: "This iPhone could not read its saved pairings from the Keychain. Unlock the iPhone and try again. Nothing was changed.")
        case .pairingNotSaved:
            return String(localized: "The pairing succeeded but this device could not save it. Check that the Keychain is available.")
        case .connectTimedOut:
            return String(localized: "The Mac did not answer in time. Check that it is awake and on the same network.")
        case .hostClosed:
            return String(localized: "The Mac closed the connection.")
        case .hostUnresponsive:
            return String(localized: "The Mac stopped answering. It may have moved networks, or the connection was interrupted.")
        case .videoLost:
            return String(localized: "The video channel did not come back.")
        case .relayTimedOut:
            return String(localized: "The relay did not answer in time.")
        case .relayHostOffline:
            return String(localized: "That Mac is not currently registered with the relay.")
        case .relayUnavailable:
            return String(localized: "The relay answered in a way this app could not use. Try again in a moment.")
        case .network(let kind):
            return message(for: kind)
        case .protocolMismatch(let client, let host):
            return String(localized: "This Mac speaks protocol v\(String(host)) and this app speaks v\(String(client)). Update whichever is older.")
        case .identityChanged(let hostID):
            return String(localized: "This Mac's identity has changed. What answered at this address (\(hostID)) does not have the key this iPhone saved when it paired. Only continue if you expect this, for example because the Mac was reset or Peering was reinstalled on it. If you do, forget this Mac here and pair again. If you do not, do not connect.")
        case .noPinOnFile(let hostID):
            return String(localized: "This iPhone has no pairing on file for that Mac (\(hostID)). The Mac still trusts this iPhone, so it will not ask to pair again: on the Mac, open Devices and forget this iPhone, then pair again.")
        case .hostIDMismatch(let dialled, let answered):
            return String(localized: "A different Mac answered: \(answered), not \(dialled). Check that the code you scanned or typed came from the Mac you meant.")
        case .relayVersionMismatch:
            return String(localized: "The Mac and this app are running different versions of Peering. Update whichever is older.")
        case .relayRefused(let message):
            return String(localized: "The relay refused the session: \(message)")
        case .hostRefused(let message):
            return String(localized: "The Mac refused the session: \(HostWireText.localized(message))")
        }
    }

    /// The phase the app keeps: the failure sentence worded for the user when it has a cause, otherwise untouched.
    static func localized(_ phase: ClientSession.Phase, cause: ClientSession.FailureCause?) -> ClientSession.Phase {
        guard case .failed = phase, let cause else { return phase }
        return .failed(message(for: cause))
    }

    static func identityMessage(for error: Error) -> String {
        if let failure = error as? SelfSignedIdentity.Failure, failure.isKeychainRefusal {
            return String(localized: "The Keychain would not give up this device's key. Unlock the iPhone and reopen Peering.")
        }
        return String(localized: "This device's key could not be created or read.")
    }

    private static func message(for kind: NetworkFailureText.Kind) -> String {
        switch kind {
        case .connectionReset:
            return String(localized: "The Mac closed the connection. It may have quit, restarted, or gone to sleep.")
        case .connectionRefused:
            return String(localized: "The Mac refused the connection. Check that Peering is running on it.")
        case .notAnswering:
            return String(localized: "The Mac did not answer. Check that both devices are on the same network.")
        case .unreachable:
            return String(localized: "The Mac could not be reached on this network.")
        case .connectionLost:
            return String(localized: "The connection to the Mac was lost.")
        case .noNetwork:
            return String(localized: "This device is not on a network.")
        case .cannotOpen:
            return String(localized: "This device could not open the connection it needs.")
        case .interrupted:
            return String(localized: "The connection to the Mac was interrupted.")
        case .hostDown:
            return String(localized: "The Mac is switched off or asleep.")
        case .failed:
            return String(localized: "The connection to the Mac failed.")
        }
    }
}
