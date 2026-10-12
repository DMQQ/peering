import Foundation
import RemoteCore

extension SessionModel {
    /// A Keychain that is locked looks like a phone with no pairings, so the user is told once instead of finding every Mac gone.
    func reportUnreadablePins() {
        if pins.takeUnreadableNotice() { pinsUnreadableNoticeShown = true }
        guard !pins.isUnreadable else { return }
        pinsUnreadableNoticeShown = false
        pairedHostIDs = pins.hostIDs
    }
}
