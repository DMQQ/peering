import MacCastKit
import RemoteCore
import SwiftUI

/// What arrives from discovery, turned into state.
///
/// **The half of the event handling that is not about a Mac.** Bonjour is a fact about the
/// phone's network rather than about any one connection: the list of Macs it can see is the same
/// list whichever of them is on screen, so the list stays here. Everything that arrives from a
/// session is applied to the session that delivered it, and lives on ``MacSession`` — see
/// ``MacSession/apply(_:)``, and the note there for why that separation is the point.
extension SessionModel {
    func apply(_ event: HostBrowser.Event) {
        switch event {
        case .started:
            browseFailed = false
            browseStatus = "Looking for Macs on this network…"
        case .updated(let hosts):
            browseFailed = false
            self.hosts = hosts
            if let pending = pendingHostID, let host = hosts.first(where: { $0.id == pending }) {
                pendingHostID = nil
                connect(to: .discovered(host))
            }
            // If we raced Bonjour on cold launch and lost, starting a relay session before the
            // local browser had time to find the Mac, switch to LAN as soon as it does appear,
            // but only while the relay has nothing on screen yet. Once the session is carrying a
            // picture, an interruption costs more than the relay does.
            //
            // **"Nothing on screen yet" and not "still dialling", which is a couple of hundred
            // milliseconds on a warm socket.** A browser that was suspended with the app usually
            // finds the Mac *after* that, and a Mac that had been on this network the whole time was
            // then left being reached over a relay in another country for the rest of the session.
            // The interruption is what the rule is protecting, so the test is the picture: see
            // ``MacSession/hasHadPicture``.
            //
            // **Replaced rather than dialled beside it, and that is a bug fix rather than a
            // tidy-up.** This is the same Mac met a moment later by a better route, not a second
            // one. Dialled as a new Mac it walked into both checks that exist for a genuinely
            // second Mac, and the one that caught it was the plan gate: the session being upgraded
            // has no `hostID` yet, because the handshake is what says what a Mac is, so the "this
            // Mac is already open" shortcut above cannot match it and the app offered to sell the
            // user a second Mac in the middle of connecting their first. Reported from the phone
            // as a second-Mac paywall appearing while reconnecting to one Mac.
            if let session = activeSession,
               session.connectionPath == .relay,
               session.phase != .ready || !session.hasHadPicture,
               let hostID = UserDefaults.standard.string(forKey: Self.lastHostIDKey),
               let host = hosts.first(where: { $0.id == hostID }) {
                // **Marked as the app's own attempt, which nothing the user did asked for.** This
                // dial hands a relay connection over to the LAN one, and without the flag the new
                // session is a Mac being opened: the connecting card goes up over a session that is
                // simply changing paths, and the picker shows underneath it while the phase is
                // `idle`. See ``MacSession/isComingBack``, which is what carries the flag the rest
                // of the way, and the cold-launch restoration, which is the other dial with this
                // shape.
                isResuming = true
                reconnect(session, to: .discovered(host))
            }
            self.resumeIfNeeded()
            // The second sentence matters more than it did: an empty list here is now the
            // moment to look at the other way in, which is the row directly below this text.
            browseStatus = hosts.isEmpty
                ? "No Macs found yet. Make sure Peering is running on your Mac and on the same network, or pair with a Mac that is not on your network."
                : "\(hosts.count) Mac\(hosts.count == 1 ? "" : "s") found"
        case .failed(let message):
            // Bonjour failing is silent on iOS without the local-network permission and the
            // NSBonjourServices entry, so the message is surfaced verbatim rather than
            // smoothed over — the manual address path below is the way past it.
            //
            // Shown even though the browser is already replacing itself: the retry can take half
            // a minute, and a status line that said nothing would leave the user looking at a
            // list that has quietly stopped updating.
            browseFailed = true
            browseStatus = "Browsing failed: \(message)"
        }
    }
}