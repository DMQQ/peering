package pl.dmq.peering.platform.discovery

import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.PeerAddress

/**
 * Turns a resolved `_remotedesktop._tcp` service into a host. The type is shared with Screen Sharing, so a service
 * without a device id is not ours and is dropped; the id is the identity, the name is only a label.
 */
object HostMapper {
    const val SERVICE_TYPE = "_remotedesktop._tcp"
    private const val KEY_ID = "id"
    private const val KEY_NAME = "name"
    private const val KEY_VERSION = "v"

    fun map(serviceName: String, attributes: Map<String, String>, address: PeerAddress): DiscoveredHost? {
        val id = attributes[KEY_ID]?.takeIf { it.isNotEmpty() } ?: return null
        return DiscoveredHost(
            id = id,
            name = attributes[KEY_NAME]?.takeIf { it.isNotBlank() } ?: serviceName,
            protocolVersion = attributes[KEY_VERSION]?.toIntOrNull(),
            address = address,
        )
    }

    /** One entry per device id, the first seen, sorted by name then id. */
    fun collapse(hosts: Collection<DiscoveredHost>): List<DiscoveredHost> =
        hosts.distinctBy { it.id }.sortedWith(compareBy({ it.name }, { it.id }))

    /** Attribute values that are not valid UTF-8 text, or absent, are treated as missing. */
    fun decodeAttributes(raw: Map<String, ByteArray?>): Map<String, String> = buildMap {
        for ((key, bytes) in raw) {
            if (bytes != null) put(key, bytes.toString(Charsets.UTF_8))
        }
    }
}
