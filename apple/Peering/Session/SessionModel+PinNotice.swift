import Foundation
import RemoteCore

extension SessionModel {
    /// A Keychain that is locked looks like a phone with no pairings, so the user is told once instead of finding every Mac gone.
    func reportUnreadablePins() {
        refreshPinRepairState()
        if pins.takeUnreadableNotice() { pinsUnreadableNoticeShown = true }
        guard !pins.isUnreadable else { return }
        pinsUnreadableNoticeShown = false
        pairedHostIDs = pins.hostIDs
    }

    func refreshPinRepairState() {
        pinsNeedReset = pins.unreadableState?.canBeReset == true
    }

    /// Deletes pairings that cannot be decoded. The Macs keep their half, so each is paired again from scratch.
    func resetPairedMacs() {
        guard pins.resetCorrupt() else {
            refreshPinRepairState()
            return
        }
        pinsNeedReset = false
        pinsUnreadableNoticeShown = false
        pairedHostIDs = pins.hostIDs
        publishKnownMacs()
        append(note: String(localized: "Paired Macs were reset. Pair each Mac again."))
    }
}
