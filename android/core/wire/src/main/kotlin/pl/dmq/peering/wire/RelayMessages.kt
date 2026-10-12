package pl.dmq.peering.wire

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/** Sixteen bytes, spelled on the wire as exactly thirty-two ASCII hex digits. */
class Token(bytes: ByteArray) {
    private val bytes: ByteArray = bytes.copyOf().also { require(it.size == SIZE) { "token must be $SIZE bytes" } }

    fun toHex(): String = bytes.toHex()

    override fun equals(other: Any?): Boolean = other is Token && other.bytes.contentEquals(bytes)

    override fun hashCode(): Int = bytes.contentHashCode()

    override fun toString(): String = "Token(redacted)"

    companion object {
        const val SIZE = 16
        private const val HEX_LENGTH = SIZE * 2

        /** Strict: exactly 32 ASCII hex digits in either case. A sign, a space or any other character is refused. */
        fun parse(hex: String): Token? {
            if (hex.length != HEX_LENGTH || !hex.all { it.isAsciiHexDigit() }) return null
            return Token(hex.hexToBytes())
        }

        private fun Char.isAsciiHexDigit(): Boolean = this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'
    }
}

class RelayMessageException(message: String) : Exception(message)

/** Messages a Mac or a phone sends to the relay. Optional fields are absent from the JSON when null. */
sealed interface RelayClientMessage {
    val type: String

    fun fields(): Map<String, JsonElement>

    /** Compact JSON with keys in sorted order, `type` included. */
    fun toJson(): String {
        val members = (fields() + ("type" to JsonPrimitive(type))).toSortedMap()
        return Json.encodeToString(JsonObject.serializer(), JsonObject(members))
    }

    data class RegisterHost(
        val deviceId: String,
        val name: String,
        val protocolVersion: Int,
        val publicKey: String? = null,
        val proof: String? = null,
        val proofTime: Long? = null,
    ) : RelayClientMessage {
        override val type = "registerHost"

        override fun fields(): Map<String, JsonElement> = buildMap {
            put("deviceId", JsonPrimitive(deviceId))
            put("name", JsonPrimitive(name))
            put("protocolVersion", JsonPrimitive(protocolVersion))
            publicKey?.let { put("publicKey", JsonPrimitive(it)) }
            proof?.let { put("proof", JsonPrimitive(it)) }
            proofTime?.let { put("proofTime", JsonPrimitive(it)) }
        }
    }

    data class ConnectToHost(
        val hostId: String,
        val clientId: String,
        val protocolVersion: Int,
        val plan: String? = null,
        val playPurchaseToken: String? = null,
        val playProductId: String? = null,
        val publicKey: String? = null,
        val proof: String? = null,
        val proofTime: Long? = null,
    ) : RelayClientMessage {
        override val type = "connectToHost"

        override fun fields(): Map<String, JsonElement> = buildMap {
            put("hostId", JsonPrimitive(hostId))
            put("clientId", JsonPrimitive(clientId))
            put("protocolVersion", JsonPrimitive(protocolVersion))
            plan?.let { put("plan", JsonPrimitive(it)) }
            playPurchaseToken?.let { put("playPurchaseToken", JsonPrimitive(it)) }
            playProductId?.let { put("playProductId", JsonPrimitive(it)) }
            publicKey?.let { put("publicKey", JsonPrimitive(it)) }
            proof?.let { put("proof", JsonPrimitive(it)) }
            proofTime?.let { put("proofTime", JsonPrimitive(it)) }
        }
    }

    data class RequestPeerAddress(val videoToken: Token) : RelayClientMessage {
        override val type = "requestPeerAddress"

        override fun fields(): Map<String, JsonElement> = mapOf("videoToken" to JsonPrimitive(videoToken.toHex()))
    }

    data class HostPresence(val hostId: String) : RelayClientMessage {
        override val type = "hostPresence"

        override fun fields(): Map<String, JsonElement> = mapOf("hostId" to JsonPrimitive(hostId))
    }

    data class ReferralStatus(
        val clientId: String,
        val publicKey: String,
        val proof: String,
        val proofTime: Long,
    ) : RelayClientMessage {
        override val type = "referralStatus"

        override fun fields(): Map<String, JsonElement> = mapOf(
            "clientId" to JsonPrimitive(clientId),
            "publicKey" to JsonPrimitive(publicKey),
            "proof" to JsonPrimitive(proof),
            "proofTime" to JsonPrimitive(proofTime),
        )
    }

    data class RedeemReferral(
        val clientId: String,
        val code: String,
        val publicKey: String,
        val proof: String,
        val proofTime: Long,
    ) : RelayClientMessage {
        override val type = "redeemReferral"

        override fun fields(): Map<String, JsonElement> = mapOf(
            "clientId" to JsonPrimitive(clientId),
            "code" to JsonPrimitive(code),
            "publicKey" to JsonPrimitive(publicKey),
            "proof" to JsonPrimitive(proof),
            "proofTime" to JsonPrimitive(proofTime),
        )
    }

    data object Ping : RelayClientMessage {
        override val type = "ping"

        override fun fields(): Map<String, JsonElement> = emptyMap()
    }

    data class NotifyDevice(
        val deviceToken: String,
        val title: String,
        val body: String,
        val source: String? = null,
        val category: String? = null,
        val sessionId: String? = null,
        val approvalId: String? = null,
    ) : RelayClientMessage {
        override val type = "notifyDevice"

        override fun fields(): Map<String, JsonElement> = buildMap {
            put("deviceToken", JsonPrimitive(deviceToken))
            put("title", JsonPrimitive(title))
            put("body", JsonPrimitive(body))
            source?.let { put("source", JsonPrimitive(it)) }
            category?.let { put("category", JsonPrimitive(it)) }
            sessionId?.let { put("sessionId", JsonPrimitive(it)) }
            approvalId?.let { put("approvalId", JsonPrimitive(it)) }
        }
    }
}

/** Messages the relay sends back. A `type` this build does not know is [Unknown], which the caller ignores. */
sealed interface RelayServerMessage {
    data class Registered(val sessionTtlSeconds: Long) : RelayServerMessage

    data class SessionReady(
        val controlHost: String,
        val controlPort: Int,
        val videoHost: String,
        val videoPort: Int,
        val controlToken: Token,
        val videoToken: Token,
    ) : RelayServerMessage

    data class HostOffline(val deviceId: String) : RelayServerMessage

    data class PeerAddress(val host: String, val port: Int) : RelayServerMessage

    data class HostPresence(val hostId: String, val online: Boolean) : RelayServerMessage

    data class Referral(val standing: RelayReferral) : RelayServerMessage

    data object Pong : RelayServerMessage

    data class Error(val code: String, val message: String) : RelayServerMessage

    data class Unknown(val type: String) : RelayServerMessage

    companion object {
        /** Throws [RelayMessageException] for text that is not a JSON object or lacks a field its type requires. */
        fun parse(text: String): RelayServerMessage {
            val root = try {
                Json.parseToJsonElement(text)
            } catch (failure: IllegalArgumentException) {
                throw RelayMessageException("relay message is not JSON: ${failure.message}")
            }
            val fields = root as? JsonObject ?: throw RelayMessageException("relay message is not a JSON object")
            return when (val type = fields.string("type")) {
                "registered" -> Registered(fields.long("sessionTtlSeconds"))
                "sessionReady" -> SessionReady(
                    controlHost = fields.string("controlHost"),
                    controlPort = fields.port("controlPort"),
                    videoHost = fields.string("videoHost"),
                    videoPort = fields.port("videoPort"),
                    controlToken = fields.token("controlToken"),
                    videoToken = fields.token("videoToken"),
                )
                "hostOffline" -> HostOffline(fields.string("deviceId"))
                "peerAddress" -> PeerAddress(fields.string("host"), fields.port("port"))
                "hostPresence" -> HostPresence(fields.string("hostId"), fields.boolean("online"))
                "referral" -> Referral(
                    RelayReferral(
                        code = fields.string("code"),
                        bonusSeconds = fields.long("bonusSeconds"),
                        bonusEndsAt = fields.optionalLong("bonusEndsAt"),
                        redeemed = fields.boolean("redeemed"),
                        invitesEarned = fields.long("invitesEarned").toInt(),
                        invitesMax = fields.long("invitesMax").toInt(),
                    ),
                )
                "pong" -> Pong
                "error" -> Error(fields.string("code"), fields.string("message"))
                else -> Unknown(type)
            }
        }

        private fun JsonObject.primitive(key: String): JsonPrimitive? = this[key] as? JsonPrimitive

        private fun JsonObject.string(key: String): String =
            primitive(key)?.takeIf { it.isString }?.content ?: throw RelayMessageException("field $key is not a string")

        private fun JsonObject.long(key: String): Long =
            primitive(key)?.takeUnless { it.isString }?.longOrNull ?: throw RelayMessageException("field $key is not a number")

        private fun JsonObject.optionalLong(key: String): Long? =
            if (this[key] == null || this[key] is JsonNull) null else long(key)

        private fun JsonObject.port(key: String): Int =
            primitive(key)?.takeUnless { it.isString }?.intOrNull?.takeIf { it in 0..MAX_PORT }
                ?: throw RelayMessageException("field $key is not a port")

        private fun JsonObject.boolean(key: String): Boolean =
            primitive(key)?.takeUnless { it.isString }?.booleanOrNull ?: throw RelayMessageException("field $key is not a boolean")

        private fun JsonObject.token(key: String): Token =
            Token.parse(string(key)) ?: throw RelayMessageException("field $key is not a 32 digit token")

        private const val MAX_PORT = 65_535
    }
}
