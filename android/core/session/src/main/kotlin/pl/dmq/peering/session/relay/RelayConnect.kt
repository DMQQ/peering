package pl.dmq.peering.session.relay

import kotlinx.coroutines.delay
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.DeviceIdentity
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.Signalling
import pl.dmq.peering.wire.PROTOCOL_VERSION
import pl.dmq.peering.wire.ProofSigner
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.Token
import pl.dmq.peering.wire.makeClientProof

/**
 * Asks the relay for a session to a Mac and for its presence, over the signalling connection. Each call reads
 * replies until the one it is waiting for; anything else the relay says (pongs, registrations) is skipped.
 */
class RelayConnect(
    private val signalling: Signalling,
    private val identity: DeviceIdentity,
    private val clock: Clock,
) {
    suspend fun requestSession(
        hostId: String,
        clientId: String,
        entitlement: RelayEntitlement = RelayEntitlement(),
    ): RelaySession = signalling.exchange(idempotent = false) {
        val proof = makeClientProof(IdentityProofSigner(identity), clientId, clock.unixSeconds())
        send(
            RelayClientMessage.ConnectToHost(
                hostId = hostId,
                clientId = clientId,
                protocolVersion = PROTOCOL_VERSION,
                plan = entitlement.plan,
                playPurchaseToken = entitlement.playPurchaseToken,
                playProductId = entitlement.playProductId,
                publicKey = proof.publicKey,
                proof = proof.signature,
                proofTime = proof.proofTime,
            ),
        )
        awaitSession(hostId)
    }

    /** Presence the relay knows for each host. A host that does not answer is absent from the map. */
    suspend fun hostPresence(hostIds: List<String>): Map<String, Boolean> {
        if (hostIds.isEmpty()) return emptyMap()
        return signalling.exchange {
            for (hostId in hostIds) {
                send(RelayClientMessage.HostPresence(hostId))
            }
            val presence = mutableMapOf<String, Boolean>()
            val outstanding = hostIds.toMutableSet()
            // Bounded, so an unexpected reply cannot keep this read going; an older relay answers an error instead.
            repeat(hostIds.size * 2 + 4) {
                if (outstanding.isEmpty()) return@exchange presence
                when (val reply = receive()) {
                    is RelayServerMessage.HostPresence -> {
                        presence[reply.hostId] = reply.online
                        outstanding.remove(reply.hostId)
                    }
                    is RelayServerMessage.Error -> return@exchange presence
                    else -> Unit
                }
            }
            presence
        }
    }

    /**
     * The address the relay has seen the Mac's datagrams come from, or null once [attempts] asks have all been
     * answered with "not known yet". Not knowing yet is the ordinary first answer, so the ask repeats.
     */
    suspend fun discoverPeer(videoToken: ByteArray, attempts: Int = 8, intervalMs: Long = 150): PeerAddress? =
        signalling.exchange {
            val token = Token(videoToken)
            repeat(maxOf(1, attempts)) { attempt ->
                send(RelayClientMessage.RequestPeerAddress(token))
                when (val reply = receive()) {
                    is RelayServerMessage.PeerAddress -> return@exchange PeerAddress(reply.host, reply.port)
                    is RelayServerMessage.Error -> {
                        if (reply.code != PEER_ADDRESS_UNKNOWN) {
                            throw RelaySessionException.Refused(reply.code, reply.message)
                        }
                        if (attempt < maxOf(1, attempts) - 1) delay(intervalMs)
                    }
                    is RelayServerMessage.SessionReady -> throw RelaySessionException.UnexpectedReply("sessionReady")
                    is RelayServerMessage.HostOffline -> throw RelaySessionException.UnexpectedReply("hostOffline")
                    else -> Unit
                }
            }
            null
        }

    private suspend fun Signalling.awaitSession(hostId: String): RelaySession {
        while (true) {
            when (val reply = receive()) {
                is RelayServerMessage.SessionReady -> return RelaySession(
                    control = PeerAddress(reply.controlHost, reply.controlPort),
                    video = PeerAddress(reply.videoHost, reply.videoPort),
                    controlToken = reply.controlToken,
                    videoToken = reply.videoToken,
                    remainingSeconds = reply.remainingSeconds,
                )
                is RelayServerMessage.HostOffline -> throw RelaySessionException.HostOffline(reply.deviceId)
                is RelayServerMessage.Error -> throw sessionError(reply, hostId)
                else -> Unit
            }
        }
    }

    private fun sessionError(reply: RelayServerMessage.Error, hostId: String): RelaySessionException =
        when (reply.code) {
            "quotaExceeded" -> RelaySessionException.QuotaExceeded
            "version" -> RelaySessionException.VersionMismatch
            "hostOffline" -> RelaySessionException.HostOffline(hostId)
            else -> RelaySessionException.Refused(reply.code, reply.message)
        }

    private companion object {
        const val PEER_ADDRESS_UNKNOWN = "peerAddressUnknown"
    }
}

internal class IdentityProofSigner(private val identity: DeviceIdentity) : ProofSigner {
    override fun publicKey(): ByteArray = identity.publicKey

    override fun sign(message: ByteArray): ByteArray = identity.sign(message)
}
