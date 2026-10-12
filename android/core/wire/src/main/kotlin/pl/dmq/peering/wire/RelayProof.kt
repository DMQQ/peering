package pl.dmq.peering.wire

private const val HOST_REGISTRATION_DOMAIN = "peeringd-host-registration-v1"
private const val CLIENT_REGISTRATION_DOMAIN = "peeringd-client-registration-v1"
private const val REFERRAL_DOMAIN = "peeringd-referral-v1"

/** The signed text is UTF-8 with newline separators and no trailing newline. */
fun hostPayload(deviceId: String, proofTime: Long): ByteArray =
    payload(HOST_REGISTRATION_DOMAIN, deviceId, proofTime.toString())

fun clientPayload(clientId: String, proofTime: Long): ByteArray =
    payload(CLIENT_REGISTRATION_DOMAIN, clientId, proofTime.toString())

fun referralStatusPayload(clientId: String, proofTime: Long): ByteArray =
    payload(REFERRAL_DOMAIN, "status", clientId, proofTime.toString())

fun redeemReferralPayload(clientId: String, code: String, proofTime: Long): ByteArray =
    payload(REFERRAL_DOMAIN, "redeem:$code", clientId, proofTime.toString())

private fun payload(vararg parts: String): ByteArray = parts.joinToString("\n").toByteArray(Charsets.UTF_8)

/** Lowercase hex of the P-256 point and the DER signature, as the relay reads them. */
data class DeviceProof(
    val publicKey: String,
    val signature: String,
    val proofTime: Long,
) {
    companion object {
        fun fromBytes(publicKey: ByteArray, derSignature: ByteArray, proofTime: Long): DeviceProof =
            DeviceProof(publicKey.toHex(), derSignature.toHex(), proofTime)
    }
}

/** Implemented by the platform key store. The implementation hashes [message] with SHA-256 as part of ECDSA. */
interface ProofSigner {
    fun publicKey(): ByteArray

    fun sign(message: ByteArray): ByteArray
}

fun makeHostProof(signer: ProofSigner, deviceId: String, nowUnix: Long): DeviceProof =
    signedProof(signer, hostPayload(deviceId, nowUnix), nowUnix)

fun makeClientProof(signer: ProofSigner, clientId: String, nowUnix: Long): DeviceProof =
    signedProof(signer, clientPayload(clientId, nowUnix), nowUnix)

fun makeReferralStatusProof(signer: ProofSigner, clientId: String, nowUnix: Long): DeviceProof =
    signedProof(signer, referralStatusPayload(clientId, nowUnix), nowUnix)

fun makeRedeemReferralProof(signer: ProofSigner, clientId: String, code: String, nowUnix: Long): DeviceProof =
    signedProof(signer, redeemReferralPayload(clientId, code, nowUnix), nowUnix)

private fun signedProof(signer: ProofSigner, message: ByteArray, proofTime: Long): DeviceProof =
    DeviceProof.fromBytes(signer.publicKey(), signer.sign(message), proofTime)
