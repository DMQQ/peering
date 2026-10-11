package pl.dmq.peering.session.relay

import pl.dmq.peering.session.ports.PeerAddress

/** What the owner of a [DirectPathProber] does on its behalf. */
sealed interface ProbeAction {
    /** Ask the relay for the Mac's address, then report the answer with onPeerAddress or onPeerAddressUnknown. */
    data object AskRelay : ProbeAction

    /** Send one sealed direct probe to [address]. */
    data class SendProbe(val address: PeerAddress) : ProbeAction

    /** The state changed since the last report. */
    data class Report(val state: DirectPathState) : ProbeAction
}
