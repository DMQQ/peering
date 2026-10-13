package pl.dmq.peering.session.hosts

import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.session.ports.PeerAddress

/** The last local address each paired host was seen at, so a dial can start before discovery has answered. */
class RememberedLanAddresses(private val store: KeyValueStore) {
    @Synchronized
    fun addressOf(hostId: String): PeerAddress? = read()[hostId]?.let(::parse)

    @Synchronized
    fun remember(hostId: String, address: PeerAddress) {
        val entries = read()
        val text = "${address.host}$SEPARATOR${address.port}"
        if (entries[hostId] == text) return
        store.write(KEY, (entries + (hostId to text)).entries.joinToString("\n") { "${it.key}$SEPARATOR${it.value}" })
    }

    private fun read(): Map<String, String> = store.read(KEY).orEmpty().lines()
        .mapNotNull { line -> line.split(SEPARATOR, limit = 2).takeIf { it.size == 2 } }
        .associate { it[0] to it[1] }

    private fun parse(text: String): PeerAddress? {
        val at = text.lastIndexOf(SEPARATOR)
        val port = text.substring(at + 1).toIntOrNull() ?: return null
        return if (at > 0) PeerAddress(text.substring(0, at), port) else null
    }

    private companion object {
        const val KEY = "remembered-lan-addresses"
        const val SEPARATOR = "|"
    }
}
