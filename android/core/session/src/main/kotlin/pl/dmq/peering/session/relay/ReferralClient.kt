package pl.dmq.peering.session.relay

import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.DeviceIdentity
import pl.dmq.peering.session.ports.Signalling
import pl.dmq.peering.wire.ReferralCode
import pl.dmq.peering.wire.ReferralRefusal
import pl.dmq.peering.wire.RelayClientMessage
import pl.dmq.peering.wire.RelayReferral
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.makeRedeemReferralProof
import pl.dmq.peering.wire.makeReferralStatusProof

/** The relay turned a redemption away. */
class ReferralRefused(val refusal: ReferralRefusal) : Exception("The relay refused the invite code: $refusal")

/**
 * Asks the relay for this device's invite code and standing, and redeems somebody else's code. Both requests are
 * signed with the device key: the bonus belongs to the key, so a made-up ID earns nothing.
 */
class ReferralClient(
    private val signalling: Signalling,
    private val identity: DeviceIdentity,
    private val clock: Clock,
) {
    suspend fun status(): RelayReferral = signalling.exchange {
        val proof = makeReferralStatusProof(IdentityProofSigner(identity), identity.clientId, clock.unixSeconds())
        send(RelayClientMessage.ReferralStatus(identity.clientId, proof.publicKey, proof.signature, proof.proofTime))
        awaitStanding()
    }

    /** Throws [ReferralRefused] when the relay says no, and the signalling's own exception when it cannot be reached. */
    suspend fun redeem(typed: String): RelayReferral = signalling.exchange {
        val code = ReferralCode.canonical(typed)
        val proof = makeRedeemReferralProof(IdentityProofSigner(identity), identity.clientId, code, clock.unixSeconds())
        send(RelayClientMessage.RedeemReferral(identity.clientId, code, proof.publicKey, proof.signature, proof.proofTime))
        awaitStanding()
    }

    private suspend fun Signalling.awaitStanding(): RelayReferral {
        while (true) {
            when (val reply = receive()) {
                is RelayServerMessage.Referral -> return reply.standing
                is RelayServerMessage.Error -> throw ReferralRefused(ReferralRefusal.of(reply.code))
                else -> Unit
            }
        }
    }
}
