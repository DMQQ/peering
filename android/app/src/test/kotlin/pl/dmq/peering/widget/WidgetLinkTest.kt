package pl.dmq.peering.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WidgetLinkTest {
    @Test
    fun connectLinkNamesTheComputer() {
        assertEquals("peering://connect?id=abc", WidgetLink.connect("abc"))
        assertEquals(WidgetLink.Connect("abc"), WidgetLink.parse(WidgetLink.connect("abc")))
    }

    @Test
    fun connectLinkWithoutAComputerMeansTheLastOne() {
        assertEquals("peering://connect", WidgetLink.connect(null))
        assertEquals(WidgetLink.Connect(null), WidgetLink.parse("peering://connect"))
    }

    @Test
    fun chatLinkCarriesChatAndComputerThroughEncoding() {
        val link = WidgetLink.chat("a b&c", "h=1")
        assertEquals(WidgetLink.Chat("a b&c", "h=1"), WidgetLink.parse(link))
    }

    @Test
    fun chatLinkWithoutAChatIdIsRejected() {
        assertNull(WidgetLink.parse("peering://chat?host=h"))
    }

    @Test
    fun foreignAddressesAreRejected() {
        assertNull(WidgetLink.parse(null))
        assertNull(WidgetLink.parse("https://connect?id=a"))
        assertNull(WidgetLink.parse("peering://other?id=a"))
    }

    @Test
    fun targetHostIdIsTheComputerEitherLinkNames() {
        assertEquals("h", WidgetLink.Connect("h").targetHostId)
        assertEquals("h", WidgetLink.Chat("c", "h").targetHostId)
        assertNull(WidgetLink.Chat("c", null).targetHostId)
    }

    @Test
    fun `a malformed percent escape parses to nothing instead of throwing`() {
        assertNull(WidgetLink.parse("peering://connect?id=%zz"))
        assertNull(WidgetLink.parse("peering://chat?id=%"))
    }
}
