package pl.dmq.peering.feature.agents.preview

import java.io.ByteArrayInputStream
import java.io.InputStream
import pl.dmq.peering.wire.PreviewFailure
import pl.dmq.peering.wire.PreviewHeader

/** What the web view is given for one request: a status line, a type, headers and a body that is read as it arrives. */
class PreviewReply(
    val status: Int,
    val reason: String,
    val mimeType: String,
    val charset: String?,
    val headers: Map<String, String>,
    val body: InputStream,
) {
    companion object {
        private const val DEFAULT_MIME = "application/octet-stream"
        private val dropped = setOf("content-type", "content-length", "transfer-encoding", "connection")

        /**
         * The computer's answer as a reply. A status in the 300s that was not followed is passed as 200, since a web
         * view refuses to be given one; a status outside HTTP's range is a bad gateway.
         */
        fun from(status: Int, headers: List<PreviewHeader>, body: InputStream): PreviewReply {
            val type = headers.firstOrNull { it.name.equals("content-type", ignoreCase = true) }?.value
            val (mime, charset) = splitContentType(type)
            val shown = when {
                status !in HTTP_RANGE -> BAD_GATEWAY
                status in REDIRECT_RANGE -> OK
                else -> status
            }
            return PreviewReply(shown, reasonPhrase(shown), mime, charset, merged(headers), body)
        }

        /** A short plain-text answer for a request that could not be carried. */
        fun failure(reason: PreviewFailure): PreviewReply = text(statusFor(reason), "Preview: ${reason.name.lowercase()}")

        fun text(status: Int, message: String): PreviewReply =
            PreviewReply(status, reasonPhrase(status), "text/plain", "utf-8", emptyMap(), ByteArrayInputStream(message.toByteArray()))

        /** A page that moves the web view to [url]: a scheme-less redirect cannot move its address from inside a response. */
        fun redirectPage(url: String): PreviewReply {
            val html = "<!doctype html><meta charset=utf-8><script>location.replace(\"${escaped(url)}\")</script>"
            return PreviewReply(OK, reasonPhrase(OK), "text/html", "utf-8", emptyMap(), ByteArrayInputStream(html.toByteArray()))
        }

        fun statusFor(reason: PreviewFailure): Int = when (reason) {
            PreviewFailure.NOT_ALLOWED -> FORBIDDEN
            PreviewFailure.INVALID_REQUEST -> BAD_REQUEST
            PreviewFailure.TOO_LARGE -> PAYLOAD_TOO_LARGE
            PreviewFailure.TIMED_OUT -> GATEWAY_TIMEOUT
            PreviewFailure.BUSY, PreviewFailure.DISCONNECTED -> SERVICE_UNAVAILABLE
            PreviewFailure.NOT_LISTENING, PreviewFailure.FAILED -> BAD_GATEWAY
        }

        fun reasonPhrase(status: Int): String = when (status) {
            OK -> "OK"
            PARTIAL -> "Partial Content"
            NO_CONTENT -> "No Content"
            BAD_REQUEST -> "Bad Request"
            FORBIDDEN -> "Forbidden"
            NOT_FOUND -> "Not Found"
            NOT_IMPLEMENTED -> "Not Implemented"
            PAYLOAD_TOO_LARGE -> "Payload Too Large"
            BAD_GATEWAY -> "Bad Gateway"
            SERVICE_UNAVAILABLE -> "Service Unavailable"
            GATEWAY_TIMEOUT -> "Gateway Timeout"
            else -> if (status < SERVER_ERRORS) "Status" else "Error"
        }

        /** One value per header name, repeats joined in the sender's order and named as first spelled. */
        private fun merged(headers: List<PreviewHeader>): Map<String, String> {
            val spelled = LinkedHashMap<String, String>()
            val values = HashMap<String, String>()
            for (header in headers) {
                val key = header.name.lowercase()
                if (key in dropped) continue
                spelled.putIfAbsent(key, header.name)
                values.merge(key, header.value) { old, new -> "$old, $new" }
            }
            return spelled.entries.associate { (key, name) -> name to values.getValue(key) }
        }

        internal fun splitContentType(value: String?): Pair<String, String?> {
            if (value.isNullOrBlank()) return DEFAULT_MIME to null
            val parts = value.split(';').map { it.trim() }
            val charset = parts.drop(1).firstOrNull { it.startsWith("charset=", ignoreCase = true) }
                ?.substringAfter('=')?.trim('"', ' ')
            return parts[0].ifEmpty { DEFAULT_MIME } to charset
        }

        private fun escaped(url: String): String =
            url.replace("\\", "%5C").replace("\"", "%22").replace("<", "%3C").replace(">", "%3E").replace("'", "%27")

        const val OK = 200
        const val NOT_IMPLEMENTED = 501
        private const val PARTIAL = 206
        private const val NO_CONTENT = 204
        private const val BAD_REQUEST = 400
        private const val FORBIDDEN = 403
        private const val NOT_FOUND = 404
        private const val PAYLOAD_TOO_LARGE = 413
        private const val BAD_GATEWAY = 502
        private const val SERVICE_UNAVAILABLE = 503
        private const val GATEWAY_TIMEOUT = 504
        private const val SERVER_ERRORS = 500
        private val HTTP_RANGE = 100..599
        private val REDIRECT_RANGE = 300..399
    }
}
