package pl.dmq.peering.session.controller

import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.PeerAddress

/** The host a session connects to, and how the phone reaches it. */
sealed interface ConnectTarget {
    /** The Mac's id when the phone knows it, or null for a host dialled by address alone. */
    val hostId: String?

    /** The route the session is expected to take. */
    val path: SessionRecord.Path

    /** A host on the local network at [address]. [hostId] is set when the phone already knows which Mac it dials. */
    data class Lan(val address: PeerAddress, override val hostId: String? = null) : ConnectTarget {
        override val path: SessionRecord.Path get() = SessionRecord.Path.LAN
    }

    /** A host reached through the relay, which must already be paired. */
    data class Relay(override val hostId: String) : ConnectTarget {
        override val path: SessionRecord.Path get() = SessionRecord.Path.RELAY
    }

    /** A host the phone has not paired with yet, found on the local network. [qrSecret] comes from a scanned code. */
    class Pairing(override val hostId: String, val qrSecret: ByteArray? = null) : ConnectTarget {
        override val path: SessionRecord.Path get() = SessionRecord.Path.LAN
    }
}
