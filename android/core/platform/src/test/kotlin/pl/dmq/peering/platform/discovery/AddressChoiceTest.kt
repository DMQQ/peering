package pl.dmq.peering.platform.discovery

import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AddressChoiceTest {
    private fun address(literal: String): InetAddress = InetAddress.getByName(literal)

    @Test
    fun prefersIpv4OverAnIpv6ListedFirst() {
        val chosen = AddressChoice.best(listOf(address("fe80::1"), address("2001:db8::5"), address("192.168.1.20")))
        assertEquals(address("192.168.1.20"), chosen)
    }

    @Test
    fun skipsLinkLocalIpv6WhenARoutableIpv6Exists() {
        val chosen = AddressChoice.best(listOf(address("fe80::1"), address("2001:db8::5")))
        assertEquals(address("2001:db8::5"), chosen)
    }

    @Test
    fun fallsBackToLinkLocalWhenNothingElseWasAdvertised() {
        assertEquals(address("fe80::1"), AddressChoice.best(listOf(address("fe80::1"))))
    }

    @Test
    fun noAddressesGivesNone() {
        assertNull(AddressChoice.best(emptyList()))
    }
}
