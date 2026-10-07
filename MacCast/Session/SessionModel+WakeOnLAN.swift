import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

extension SessionModel {
    /// A magic packet is an unacknowledged UDP broadcast, so silence would look like a row that did nothing; the sentence carries the limit that it does not leave the network.
    func wakeHost(id: String) {
        Analytics.featureUsed(.wakeOnLAN)
        let addresses = hostMACAddresses[id] ?? []
        let sent = addresses.filter { WakeOnLAN.send(to: $0) }.count
        guard sent > 0 else {
            append(note: addresses.isEmpty
                ? String(localized: "No hardware address is on file for that Mac, so there is nothing to send a wake packet to.")
                : String(localized: "That Mac's stored hardware address could not be read, so no wake packet was sent."))
            return
        }
        append(note: sent == 1
            ? String(localized: "Wake packet sent to 1 hardware address. It can only reach a Mac on this network.")
            : String(localized: "Wake packet sent to \(sent) hardware addresses. It can only reach a Mac on this network."))
    }
}
