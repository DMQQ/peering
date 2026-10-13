import Foundation

extension HostWireText {
    /// Pairing refusals from the Mac and the sentences `RemoteCore` raises while connecting.
    static func connection(_ text: String) -> String? {
        switch text {
        case "The codes did not match.": String(localized: "The codes did not match.")
        case "The pairing code was not accepted.": String(localized: "The pairing code was not accepted.")
        case "The pairing was declined on the Mac.": String(localized: "The pairing was declined on the Mac.")
        case "Another device is pairing with this Mac right now. Try again in a minute.":
            String(localized: "Another device is pairing with this Mac right now. Try again in a minute.")
        case "Too many pairing attempts. Try again in a minute.": String(localized: "Too many pairing attempts. Try again in a minute.")
        case "Could not save the pairing.": String(localized: "Could not save the pairing.")
        case "The Mac refused the pairing.": String(localized: "The Mac refused the pairing.")
        case "The pairing succeeded but this device could not save it. Check that the Keychain is available.":
            String(localized: "The pairing succeeded but this device could not save it. Check that the Keychain is available.")
        case "The Mac closed the connection. It may have quit, restarted, or gone to sleep.":
            String(localized: "The Mac closed the connection. It may have quit, restarted, or gone to sleep.")
        case "The Mac refused the connection. Check that Peering is running on it.":
            String(localized: "The Mac refused the connection. Check that Peering is running on it.")
        case "The Mac did not answer. Check that both devices are on the same network.":
            String(localized: "The Mac did not answer. Check that both devices are on the same network.")
        case "The Mac could not be reached on this network.": String(localized: "The Mac could not be reached on this network.")
        case "The connection to the Mac was lost.": String(localized: "The connection to the Mac was lost.")
        case "This device is not on a network.": String(localized: "This device is not on a network.")
        case "This device could not open the connection it needs.": String(localized: "This device could not open the connection it needs.")
        case "The connection to the Mac was interrupted.": String(localized: "The connection to the Mac was interrupted.")
        case "The Mac is switched off or asleep.": String(localized: "The Mac is switched off or asleep.")
        case "The connection to the Mac failed.": String(localized: "The connection to the Mac failed.")
        case "The Mac stopped answering. It may have moved networks, or the connection was interrupted.":
            String(localized: "The Mac stopped answering. It may have moved networks, or the connection was interrupted.")
        case "The video channel did not come back.": String(localized: "The video channel did not come back.")
        case "The connection ended.": String(localized: "The connection ended.")
        case "The Mac reported an error.": String(localized: "The Mac reported an error.")
        case "This session is already connecting or connected.": String(localized: "This session is already connecting or connected.")
        case "Hosting stopped on this Mac.": String(localized: "Hosting stopped on this Mac.")
        case "The server did not answer in time.": String(localized: "The server did not answer in time.")
        default: nil
        }
    }
}
