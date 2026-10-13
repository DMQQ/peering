package pl.dmq.peering.wire

/**
 * Pairing QR payloads. `peering://pair?code=NNNNNN[&secret=hex]` carries the six digit code that both screens compare.
 * `https://getpeering.app/mac?id=<UUID>` carries the Mac's device ID. Each parser refuses the other's payload, so a
 * scan of the wrong code is reported as a mismatch rather than read as the other thing.
 */
sealed class PairingPayloadError(message: String) : IllegalArgumentException(message) {
    data object EmptyInput : PairingPayloadError("no device ID was given")

    /** The six digit pairing code arrived where the device ID belongs. */
    data object ShortAuthenticationCode : PairingPayloadError("the six digit pairing code was given instead of the device ID")

    data object UnrecognisedCode : PairingPayloadError("the QR code is not a Peering pairing code")

    data class NotAnIdentifier(val text: String) : PairingPayloadError("not a device ID: $text")
}

object PairingPayload {
    const val SCHEME = "peering"
    const val CODE_HOST = "pair"
    const val IDENTIFIER_HOST = "mac"
    const val CODE_KEY = "code"
    const val SECRET_KEY = "secret"
    const val LINK_DOMAIN = "getpeering.app"
    const val LINK_PATH = "/mac"
    const val IDENTIFIER_KEY = "id"

    private const val CODE_DIGITS = 6
    private const val UUID_LENGTH = 36
    private val UUID_HYPHENS = setOf(8, 13, 18, 23)

    /** The device ID link. The ID is written uppercase, because the relay matches it exactly. */
    fun hostLink(hostId: String): String = "https://$LINK_DOMAIN$LINK_PATH?$IDENTIFIER_KEY=${hostId.uppercase()}"

    /** The pairing code link. The secret, when given, is written as lowercase hex. */
    fun codeLink(code: String, secret: ByteArray? = null): String {
        val base = "$SCHEME://$CODE_HOST?$CODE_KEY=$code"
        return if (secret == null) base else "$base&$SECRET_KEY=${secret.toHex()}"
    }

    /** The six digit code from raw text: either the bare digits or a pairing code link. Null when it is neither. */
    fun code(raw: String): String? {
        val text = raw.trim()
        if (isAuthenticationCode(text)) return text
        val link = Link.parse(text) ?: return null
        if (!link.isPairingCodeLink()) return null
        return queryValue(link.query, CODE_KEY)?.takeIf(::isAuthenticationCode)
    }

    /** The pairing secret carried by a pairing code link. Null for a code without one, or a secret that is not hex. */
    fun secret(raw: String): ByteArray? {
        val link = Link.parse(raw.trim()) ?: return null
        if (!link.isPairingCodeLink()) return null
        val hex = queryValue(link.query, SECRET_KEY) ?: return null
        if (hex.isEmpty() || hex.length % 2 != 0 || !hex.all(::isHexDigit)) return null
        return hex.hexToBytes()
    }

    /** The uppercase device ID from a bare UUID or a device ID link. Refuses the pairing code, which looks like a number. */
    fun hostId(raw: String): String {
        val text = raw.trim()
        if (text.isEmpty()) throw PairingPayloadError.EmptyInput
        if (isUuid(text)) return text.uppercase()
        if (isAuthenticationCode(text)) throw PairingPayloadError.ShortAuthenticationCode
        val link = Link.parse(text) ?: throw unparseable(text)
        return when {
            link.scheme == "https" && isDeviceLinkHost(link.host) && link.path == LINK_PATH -> identifierIn(link)
            link.scheme == SCHEME && link.host == CODE_HOST -> throw PairingPayloadError.ShortAuthenticationCode
            link.scheme == SCHEME && link.host == IDENTIFIER_HOST -> identifierIn(link)
            else -> throw PairingPayloadError.UnrecognisedCode
        }
    }

    private fun unparseable(text: String): PairingPayloadError =
        if (hasSchemePrefix(text)) PairingPayloadError.UnrecognisedCode else PairingPayloadError.NotAnIdentifier(text)

    private fun identifierIn(link: Link): String {
        val value = queryValue(link.query, IDENTIFIER_KEY).orEmpty()
        if (!isUuid(value)) throw PairingPayloadError.NotAnIdentifier(value)
        return value.uppercase()
    }

    private fun Link.isPairingCodeLink(): Boolean = scheme == SCHEME && host == CODE_HOST

    private fun isDeviceLinkHost(host: String): Boolean = host == LINK_DOMAIN || host == "www.$LINK_DOMAIN"

    private fun isAuthenticationCode(text: String): Boolean =
        text.length == CODE_DIGITS && text.all { it in '0'..'9' }

    private fun isUuid(text: String): Boolean =
        text.length == UUID_LENGTH && text.withIndex().all { (index, char) ->
            if (index in UUID_HYPHENS) char == '-' else isHexDigit(char)
        }

    private fun isHexDigit(char: Char): Boolean = char in '0'..'9' || char in 'a'..'f' || char in 'A'..'F'

    /** `scheme:` with a plain letter scheme, so `WIFI:S:...` reads as another format and `my mac` as a mistyped ID. */
    private fun hasSchemePrefix(text: String): Boolean {
        val scheme = text.substringBefore(':', missingDelimiterValue = "")
        return scheme.isNotEmpty() && scheme.all { it in 'a'..'z' || it in 'A'..'Z' }
    }

    /** The first value for [key]; every value read here (digits, hex, UUID) needs no percent decoding. */
    private fun queryValue(query: String, key: String): String? =
        query.split('&').firstNotNullOfOrNull { pair ->
            val separator = pair.indexOf('=')
            if (separator >= 0 && pair.substring(0, separator) == key) pair.substring(separator + 1) else null
        }
}

/**
 * A URL split into the parts the parsers compare. The scheme and host are lowercased; the query is left as written.
 */
private class Link(val scheme: String, val host: String, val path: String, val query: String) {
    companion object {
        fun parse(text: String): Link? {
            val withoutFragment = text.substringBefore('#')
            val separator = withoutFragment.indexOf("://")
            if (separator < 0) return null
            val scheme = withoutFragment.substring(0, separator)
            if (scheme.isEmpty() || !scheme.all { it in 'a'..'z' || it in 'A'..'Z' }) return null
            val rest = withoutFragment.substring(separator + 3)
            val beforeQuery = rest.substringBefore('?')
            val query = rest.substringAfter('?', missingDelimiterValue = "")
            val pathStart = beforeQuery.indexOf('/')
            val authority = if (pathStart < 0) beforeQuery else beforeQuery.substring(0, pathStart)
            val path = if (pathStart < 0) "" else beforeQuery.substring(pathStart)
            return Link(scheme.lowercase(), authority.lowercase(), path, query)
        }
    }
}
