package pl.dmq.peering.session.preview

import pl.dmq.peering.wire.PreviewFailure
import pl.dmq.peering.wire.PreviewHeader
import pl.dmq.peering.wire.PreviewProxyRequest

/**
 * What the computer will fetch for the phone's web preview, decided without a network so it can be tested. The proxy
 * is not a general one: it dials 127.0.0.1 and nothing else, on a port the request names, and never the port the host
 * itself listens on.
 */
object PreviewPolicy {
    /** The port the host app listens on for phones. */
    const val HOST_PORT = 51515
    const val MAX_TARGET_LENGTH = 8 * 1024
    const val MAX_HEADER_COUNT = 64
    const val MAX_REQUEST_BODY_BYTES = 256 * 1024

    /** What one response may add up to on the phone before it is cut off, however the computer sizes its own limit. */
    const val MAX_RESPONSE_BYTES = 32L * 1024 * 1024

    /** Methods that can be carried: the phone's web view does not hand over a request body, so those that need one are not offered. */
    val carriedMethods: Set<String> = setOf("GET", "HEAD", "OPTIONS", "DELETE")
    private val serverMethods: Set<String> = setOf("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS")
    private val loopbackHosts: Set<String> = setOf("localhost", "127.0.0.1")

    private val requestHeaders: Set<String> = setOf(
        "accept", "accept-language", "content-type", "user-agent", "if-none-match", "if-modified-since",
        "range", "authorization", "cookie", "origin", "referer",
    )

    fun isLoopbackHost(host: String): Boolean = host.lowercase() in loopbackHosts

    fun isAllowed(port: Int): Boolean = port in 1..MAX_PORT && port != HOST_PORT

    /** Null when the request may be sent. */
    fun refusal(request: PreviewProxyRequest): PreviewFailure? {
        if (!isAllowed(request.port) || request.method !in serverMethods) return PreviewFailure.NOT_ALLOWED
        if (!isValidTarget(request.target) || request.headers.size > MAX_HEADER_COUNT) return PreviewFailure.INVALID_REQUEST
        return null
    }

    /** A single leading `/` and nothing that could turn the string into another authority or split a header. */
    fun isValidTarget(target: String): Boolean {
        if (!target.startsWith("/") || target.startsWith("//") || target.toByteArray().size > MAX_TARGET_LENGTH) return false
        return target.all { it.code > SPACE && it.code != DELETE && it != '\\' }
    }

    /** Only what a page needs; host, framing and connection headers are the proxy's own. */
    fun filteredRequestHeaders(headers: Map<String, String>): List<PreviewHeader> = headers.mapNotNull { (name, value) ->
        val lower = name.lowercase()
        if ((lower in requestHeaders || lower.startsWith("x-")) && isSafe(name, value)) PreviewHeader(name, value) else null
    }.take(MAX_HEADER_COUNT)

    private fun isSafe(name: String, value: String): Boolean =
        name.isNotEmpty() && ':' !in name && name.none(::isForbidden) && value.none(::isForbidden)

    private fun isForbidden(char: Char): Boolean = char == '\r' || char == '\n' || char == '\u0000'

    private const val MAX_PORT = 65535
    private const val SPACE = 0x20
    private const val DELETE = 0x7F
}
