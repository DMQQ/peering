package pl.dmq.peering.platform.discovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.PeerAddress

class HostMapperTest {
    private val address = PeerAddress("192.168.1.20", 51515)

    private fun host(id: String, name: String, port: Int = 51515) =
        DiscoveredHost(id = id, name = name, protocolVersion = 20, address = PeerAddress("10.0.0.1", port))

    @Test
    fun serviceWithIdBecomesAHostWithItsAttributes() {
        val host = HostMapper.map("Mac", mapOf("id" to "ABC", "name" to "Studio", "v" to "20"), address)

        assertEquals(DiscoveredHost("ABC", "Studio", 20, address), host)
    }

    @Test
    fun serviceWithoutIdIsDropped() {
        assertNull(HostMapper.map("Other Mac", mapOf("name" to "Studio"), address))
    }

    @Test
    fun emptyIdIsDropped() {
        assertNull(HostMapper.map("Mac", mapOf("id" to ""), address))
    }

    @Test
    fun missingNameFallsBackToTheServiceName() {
        val host = HostMapper.map("Mac mini", mapOf("id" to "ABC"), address)

        assertEquals("Mac mini", host?.name)
    }

    @Test
    fun blankNameFallsBackToTheServiceName() {
        val host = HostMapper.map("Mac mini", mapOf("id" to "ABC", "name" to "   "), address)

        assertEquals("Mac mini", host?.name)
    }

    @Test
    fun unreadableVersionIsNull() {
        val host = HostMapper.map("Mac", mapOf("id" to "ABC", "v" to "twenty"), address)

        assertNull(host?.protocolVersion)
    }

    @Test
    fun collapseKeepsOneEntryPerIdAndTheFirstAddress() {
        val collapsed = HostMapper.collapse(
            listOf(host("ABC", "Studio", port = 1), host("ABC", "Studio", port = 2), host("DEF", "Office")),
        )

        assertEquals(listOf("DEF", "ABC"), collapsed.map { it.id })
        assertEquals(1, collapsed.first { it.id == "ABC" }.address.port)
    }

    @Test
    fun collapseSortsByNameThenId() {
        val collapsed = HostMapper.collapse(listOf(host("ZZZ", "Beta"), host("AAA", "Alpha"), host("BBB", "Alpha")))

        assertEquals(listOf("AAA", "BBB", "ZZZ"), collapsed.map { it.id })
    }

    @Test
    fun decodeAttributesDropsMissingValues() {
        val decoded = HostMapper.decodeAttributes(mapOf("id" to "ABC".toByteArray(), "name" to null))

        assertEquals(mapOf("id" to "ABC"), decoded)
    }
}
