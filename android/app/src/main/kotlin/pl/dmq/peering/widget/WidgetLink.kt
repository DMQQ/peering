package pl.dmq.peering.widget

import java.net.URLDecoder
import java.net.URLEncoder

/** The addresses a widget tap carries into the app: which computer to open, and for a chat which one. */
sealed interface WidgetLink {
    /** A null [hostId] means the computer last used. */
    data class Connect(val hostId: String?) : WidgetLink

    data class Chat(val chatId: String, val hostId: String?) : WidgetLink

    /** Ends the session on screen. It comes from outside the app only, and asks first when a session is live. */
    data object Disconnect : WidgetLink

    /** The computer the link asks to open, if it names one. */
    val targetHostId: String? get() = when (this) {
        is Connect -> hostId
        is Chat -> hostId
        Disconnect -> null
    }

    companion object {
        const val SCHEME = "peering"

        fun connect(hostId: String?): String = build("connect", listOf("id" to hostId))

        fun disconnect(): String = build("disconnect", emptyList())

        fun chat(chatId: String, hostId: String?): String = build("chat", listOf("id" to chatId, "host" to hostId))

        fun parse(text: String?): WidgetLink? {
            val prefix = "$SCHEME://"
            if (text == null || !text.startsWith(prefix)) return null
            val rest = text.removePrefix(prefix)
            val query = runCatching {
                rest.substringAfter('?', "").split('&').filter { it.contains('=') }.associate {
                    decode(it.substringBefore('=')) to decode(it.substringAfter('='))
                }
            }.getOrNull() ?: return null
            return when (rest.substringBefore('?')) {
                "connect" -> Connect(query["id"]?.takeIf { it.isNotEmpty() })
                "disconnect" -> Disconnect
                "chat" -> query["id"]?.takeIf { it.isNotEmpty() }?.let { Chat(it, query["host"]?.takeIf { host -> host.isNotEmpty() }) }
                else -> null
            }
        }

        private fun build(target: String, parameters: List<Pair<String, String?>>): String {
            val query = parameters.mapNotNull { (key, value) -> value?.let { "$key=${URLEncoder.encode(it, "UTF-8")}" } }
            return "$SCHEME://$target" + if (query.isEmpty()) "" else "?" + query.joinToString("&")
        }

        private fun decode(value: String): String = URLDecoder.decode(value, "UTF-8")
    }
}
