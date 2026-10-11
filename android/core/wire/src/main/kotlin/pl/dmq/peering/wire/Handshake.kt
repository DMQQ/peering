package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/** Byte fields travel as padded base64 text; the `...Bytes` accessors decode them on demand. */
@Serializable
data class ClientHello(
    val clientID: String,
    val clientName: String,
    val protocolVersion: Int,
    val wantsPairing: Boolean,
    val supportsClipboardImages: Boolean? = null,
    val supportsTextFocus: Boolean? = null,
    val supportsFieldState: Boolean? = null,
    val supportsPointerReport: Boolean? = null,
    val supportsAgentChat: Boolean? = null,
    val supportsAgentPermissionModes: Boolean? = null,
    val supportsAgentUsage: Boolean? = null,
    val lostPairing: Boolean? = null,
    val resumeSource: JsonElement? = null,
) {
    companion object {
        /** The host skips pairing for a pinned key unless the phone says it lost the pin for this Mac. */
        fun hostTreatsAsPaired(pinned: Boolean, lostPairing: Boolean?): Boolean = pinned && lostPairing != true
    }
}

@Serializable
data class ServerHello(
    val serverID: String,
    val hostName: String,
    val protocolVersion: Int,
    val alreadyPaired: Boolean,
    val macAddresses: List<String>? = null,
    val supportsVideoPause: Boolean? = null,
    val supportsClipboardImages: Boolean? = null,
    val supportsMosaic: Boolean? = null,
    val supportsSourceThumbnails: Boolean? = null,
    val supportsDeviceOrientation: Boolean? = null,
    val supportsVirtualDisplayManagement: Boolean? = null,
    val pushesTerminalAlertsWhileConnected: Boolean? = null,
    val supportsAgentList: Boolean? = null,
    val supportsAgentChat: Boolean? = null,
    val supportsFileBrowser: Boolean? = null,
    val supportsAgentModelPicker: Boolean? = null,
    val agentChatAgents: List<String>? = null,
    val supportsAgentPermissionModes: Boolean? = null,
    val supportsAgentUsage: Boolean? = null,
    val supportsAgentSessionImport: Boolean? = null,
    val supportsAgentPause: Boolean? = null,
)

@Serializable
data class PairingCommit(val commitment: String) {
    val commitmentBytes: ByteArray get() = commitment.fromBase64()
}

@Serializable
data class PairingReveal(val ephemeralPublicKey: String, val nonce: String) {
    val ephemeralPublicKeyBytes: ByteArray get() = ephemeralPublicKey.fromBase64()
    val nonceBytes: ByteArray get() = nonce.fromBase64()
}

/** [proof] is absent when the pairing digits were typed rather than scanned. */
@Serializable
data class PairConfirm(val accepted: Boolean, val proof: String? = null) {
    val proofBytes: ByteArray? get() = proof?.fromBase64()
}

/** [reason] is present when [accepted] is false. */
@Serializable
data class PairResult(val accepted: Boolean, val reason: String? = null)

/** A standing condition on the host. A null [message] clears it. */
@Serializable
data class NoticePayload(
    val message: String? = null,
    val symbol: String? = null,
    val lockedDisplayID: Long? = null,
)

/** A pong is matched to its ping by [sequence]. */
@Serializable
data class PingPayload(val sequence: Long)

@Serializable
data class ErrorPayload(val code: String, val message: String) {
    companion object {
        /** The user pressed Stop on the host. The client must not reconnect. */
        const val HOST_STOPPED_CODE = "hostStopped"
    }
}

@Serializable
data class VideoKeyGrant(val secret: String) {
    val secretBytes: ByteArray get() = secret.fromBase64()
}

@Serializable
enum class VideoTransportKind {
    @SerialName("primary") PRIMARY,
    @SerialName("control") CONTROL,
}

@Serializable
data class VideoTransportRequest(val transport: VideoTransportKind, val reason: String)
