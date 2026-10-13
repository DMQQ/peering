package pl.dmq.peering.session.hosts

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.ports.KeyValueStore

class HostMacAddressesTest {
    private class MapStore : KeyValueStore {
        val values = HashMap<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) { values[key] = value }
    }

    private val store = MapStore()
    private val addresses = HostMacAddresses(store)

    @Test
    fun `addresses are kept per host and survive a reopen`() {
        addresses.remember("H1", listOf("aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"))
        addresses.remember("H2", listOf("aa:bb:cc:dd:ee:03"))

        val reopened = HostMacAddresses(store)
        assertEquals(listOf("aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"), reopened.of("H1"))
        assertEquals(listOf("aa:bb:cc:dd:ee:03"), reopened.of("H2"))
        assertEquals(emptyList<String>(), reopened.of("H3"))
    }

    @Test
    fun `an empty report keeps what was known and a new one replaces it`() {
        addresses.remember("H1", listOf("aa:bb:cc:dd:ee:01"))
        addresses.remember("H1", emptyList())
        assertEquals(listOf("aa:bb:cc:dd:ee:01"), addresses.of("H1"))

        addresses.remember("H1", listOf("aa:bb:cc:dd:ee:09"))
        assertEquals(listOf("aa:bb:cc:dd:ee:09"), addresses.of("H1"))
    }

    @Test
    fun `values from the wire are clipped and cannot break the stored format`() {
        addresses.remember("H1", listOf("x".repeat(40), "a|b", "c,d", "line\nbreak") + (1..12).map { "aa:bb:cc:dd:ee:%02x".format(it) })

        val kept = addresses.of("H1")
        assertEquals(8, kept.size)
        assertEquals("x".repeat(17), kept.first())
    }

    @Test
    fun `forgetting a host drops its addresses`() {
        addresses.remember("H1", listOf("aa:bb:cc:dd:ee:01"))
        addresses.forget("H1")

        assertEquals(emptyList<String>(), addresses.of("H1"))
    }
}
