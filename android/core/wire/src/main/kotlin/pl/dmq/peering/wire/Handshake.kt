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
    val clientPlatform: String? = null,
    /** Codec names this phone decodes, best first. Absent means the phone decodes both. */
    val videoCodecs: List<String>? = null,
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
    val hostPlatform: String? = null,
    /** The host understands [ClientStatePayload]; a phone sends it only to a host that declared this. */
    val supportsClientState: Boolean? = null,
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

/** What the host's clipboard holds. An older host sends only [text], with no [kind]: absent means text. [image] is padded base64 PNG. */
@Serializable
data class ClipboardPayload(val kind: String? = null, val text: String? = null, val image: String? = null) {
    /** The text, or null when the clipboard holds something else, such as an image. */
    val plainText: String? get() = if (kind == null || kind == "text") text else null

    /** The PNG, or null when the payload is not an image, is empty, is over [MAX_CLIPBOARD_IMAGE_BYTES] or is not base64. */
    val pngBytes: ByteArray?
        get() {
            if (kind != "image" || image.isNullOrEmpty()) return null
            val bytes = try {
                image.fromBase64()
            } catch (error: IllegalArgumentException) {
                return null
            }
            return bytes.takeIf { it.isNotEmpty() && it.size <= MAX_CLIPBOARD_IMAGE_BYTES }
        }
}

/** The largest picture either end carries, as the host's own limit. */
const val MAX_CLIPBOARD_IMAGE_BYTES = 8 * 1024 * 1024

/** Above [MAX_CLIPBOARD_IMAGE_BYTES] because the host guards the base64 form. */
const val MAX_CLIPBOARD_REASSEMBLED_BYTES = 12 * 1024 * 1024

/** Whether the phone is out of the foreground, so the host can stop encoding for a phone the OS has frozen. */
@Serializable
data class ClientStatePayload(val background: Boolean)

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
