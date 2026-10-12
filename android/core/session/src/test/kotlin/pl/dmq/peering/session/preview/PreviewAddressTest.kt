package pl.dmq.peering.session.preview

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewAddressTest {
    @Test
    fun aBarePortOpensItsServerRoot() {
        assertEquals(PreviewAddress(3000, "/"), PreviewAddress.fromTyped("3000"))
        assertEquals(PreviewAddress(3000, "/"), PreviewAddress.fromTyped("  3000 "))
    }

    @Test
    fun loopbackNamesWithAPortAreTakenWithOrWithoutAScheme() {
        assertEquals(PreviewAddress(3000, "/docs?a=1"), PreviewAddress.fromTyped("localhost:3000/docs?a=1"))
        assertEquals(PreviewAddress(5173, "/"), PreviewAddress.fromTyped("127.0.0.1:5173"))
        assertEquals(PreviewAddress(3000, "/"), PreviewAddress.fromTyped("http://localhost:3000/"))
        assertEquals(PreviewAddress(8443, "/x"), PreviewAddress.fromTyped("HTTPS://LOCALHOST:8443/x"))
    }

    @Test
    fun anyOtherHostIsRefusedSoTheFieldCannotReachTheLanOrTheInternet() {
        assertNull(PreviewAddress.fromTyped("192.168.1.5:3000"))
        assertNull(PreviewAddress.fromTyped("example.com:80"))
        assertNull(PreviewAddress.fromTyped("localhost.evil.com:3000"))
        assertNull(PreviewAddress.fromTyped("user@localhost:3000"))
        assertNull(PreviewAddress.fromTyped("localhost"))
        assertNull(PreviewAddress.fromTyped("localhost:3000@evil.com"))
        assertNull(PreviewAddress.fromTyped(""))
    }

    @Test
    fun theHostsOwnPortAndOutOfRangePortsAreRefused() {
        assertNull(PreviewAddress.fromTyped("51515"))
        assertNull(PreviewAddress.fromTyped("localhost:51515/x"))
        assertNull(PreviewAddress.fromTyped("0"))
        assertNull(PreviewAddress.fromTyped("70000"))
    }

    @Test
    fun theWebViewUrlAndTheFieldShowTheSameLoopbackAddress() {
        val address = PreviewAddress(3000, "/a?b=1")
        assertEquals("http://localhost:3000/a?b=1", address.url)
        assertEquals("localhost:3000/a?b=1", address.display)
    }

    @Test
    fun aRedirectWithinLoopbackIsFollowed() {
        val from = PreviewAddress(3000, "/old")
        assertEquals(PreviewRedirect.Follow(PreviewAddress(3000, "/new")), PreviewRedirect.of(302, "/new", from))
        assertEquals(PreviewRedirect.Follow(PreviewAddress(3001, "/")), PreviewRedirect.of(301, "http://127.0.0.1:3001/", from))
        assertEquals(PreviewRedirect.Follow(PreviewAddress(3000, "/login?next=%2F")), PreviewRedirect.of(307, "https://localhost:3000/login?next=%2F", from))
    }

    @Test
    fun aRedirectOutOfLoopbackIsRefused() {
        val from = PreviewAddress(3000, "/old")
        assertEquals(PreviewRedirect.Refuse, PreviewRedirect.of(302, "https://example.com/", from))
        assertEquals(PreviewRedirect.Refuse, PreviewRedirect.of(302, "//example.com/x", from))
        assertEquals(PreviewRedirect.Refuse, PreviewRedirect.of(302, "http://localhost/", from))
        assertEquals(PreviewRedirect.Refuse, PreviewRedirect.of(302, "http://localhost:51515/", from))
    }

    @Test
    fun anAnswerWithoutARedirectIsLeftAlone() {
        val from = PreviewAddress(3000, "/")
        assertEquals(PreviewRedirect.NotARedirect, PreviewRedirect.of(200, "/new", from))
        assertEquals(PreviewRedirect.NotARedirect, PreviewRedirect.of(302, null, from))
        assertEquals(PreviewRedirect.NotARedirect, PreviewRedirect.of(304, "/new", from))
    }

    @Test
    fun onlyPlainHeadersAPageNeedsAreSentOn() {
        val kept = PreviewPolicy.filteredRequestHeaders(
            mapOf(
                "Accept" to "text/html", "Host" to "evil", "Cookie" to "a=b", "X-Requested-With" to "x",
                "Connection" to "keep-alive", "Accept" + "\r\n" to "bad", "Range" to "bytes=0-1\r\nX: y",
            ),
        )
        assertEquals(listOf("Accept", "Cookie", "X-Requested-With"), kept.map { it.name })
    }

    @Test
    fun targetsThatCouldNameAnotherAuthorityAreInvalid() {
        assertTrue(PreviewPolicy.isValidTarget("/a/b?c=d#e"))
        assertFalse(PreviewPolicy.isValidTarget("//host/x"))
        assertFalse(PreviewPolicy.isValidTarget("x"))
        assertFalse(PreviewPolicy.isValidTarget("/a b"))
        assertFalse(PreviewPolicy.isValidTarget("/a\\b"))
        assertFalse(PreviewPolicy.isValidTarget("/" + "a".repeat(PreviewPolicy.MAX_TARGET_LENGTH)))
    }

    @Test
    fun everySpellingOfThePhonesOwnLoopbackIsRecognisedEvenWhenItCannotBeUsed() {
        for (url in listOf(
            "http://localhost/", "http://localhost:51515/", "http://127.0.0.1:3000/a", "http://127.1.2.3/", "https://LOCALHOST:8443/",
            "http://[::1]:3000/", "http://0.0.0.0:80/", "http://app.localhost:3000/", "http://user@localhost:3000/", "http://localhost:3000/a b|c",
        )) {
            assertTrue(url, PreviewAddress.namesLoopback(url))
        }
    }

    @Test
    fun otherHostsAreNotTheLoopback() {
        for (url in listOf("https://example.com/", "http://192.168.1.5:3000/", "http://notlocalhost.com/", "http://example.com/?u=http://localhost/", "data:text/html,hi", "about:blank")) {
            assertFalse(url, PreviewAddress.namesLoopback(url))
        }
    }
}
