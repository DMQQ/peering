package pl.dmq.peering.wire

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class PairingPayloadTest {
    private val hostId = "3D9F1C7A-2B44-4E71-9C0A-5F2E8B1D6A33"

    @Test
    fun hostLinkWritesTheIdUppercaseAndHyphenated() {
        assertEquals(
            "https://getpeering.app/mac?id=3D9F1C7A-2B44-4E71-9C0A-5F2E8B1D6A33",
            PairingPayload.hostLink(hostId),
        )
        assertEquals(PairingPayload.hostLink(hostId), PairingPayload.hostLink(hostId.lowercase()))
    }

    @Test
    fun codeLinkWithoutASecretIsTheBareCode() {
        assertEquals("peering://pair?code=042317", PairingPayload.codeLink("042317"))
    }

    @Test
    fun codeLinkWritesTheSecretAsLowercaseHex() {
        assertEquals(
            "peering://pair?code=000001&secret=0aff",
            PairingPayload.codeLink("000001", byteArrayOf(0x0A, 0xFF.toByte())),
        )
    }

    @Test
    fun codeAcceptsBareDigitsAndKeepsLeadingZeros() {
        assertEquals("000000", PairingPayload.code("000000"))
        assertEquals("042317", PairingPayload.code(" 042317\n"))
    }

    @Test
    fun codeReadsTheCodeFromAPairingLinkWithLeadingZeros() {
        assertEquals("007000", PairingPayload.code("peering://pair?code=007000"))
        assertEquals("000123", PairingPayload.code(PairingPayload.codeLink("000123", byteArrayOf(1, 2))))
    }

    @Test
    fun codeRefusesAnythingThatIsNotSixDigits() {
        assertNull(PairingPayload.code("04231"))
        assertNull(PairingPayload.code("0423178"))
        assertNull(PairingPayload.code("04231x"))
        assertNull(PairingPayload.code(""))
        assertNull(PairingPayload.code("peering://pair?code=04231"))
        assertNull(PairingPayload.code("https://example.com/?code=042317"))
        assertNull(PairingPayload.code("peering://mac?code=042317"))
    }

    @Test
    fun secretDecodesHexInEitherCase() {
        assertArrayEquals(byteArrayOf(0x0A, 0xFF.toByte()), PairingPayload.secret("peering://pair?code=042317&secret=0aff"))
        assertArrayEquals(byteArrayOf(0x0A, 0xFF.toByte()), PairingPayload.secret("peering://pair?code=042317&secret=0AFF"))
    }

    @Test
    fun secretRoundTripsThroughCodeLink() {
        val secret = byteArrayOf(0, 15, 16, -1)
        assertArrayEquals(secret, PairingPayload.secret(PairingPayload.codeLink("123456", secret)))
    }

    @Test
    fun secretIsNullWithoutAUsableSecret() {
        assertNull(PairingPayload.secret("peering://pair?code=042317"))
        assertNull(PairingPayload.secret("peering://pair?code=042317&secret="))
        assertNull(PairingPayload.secret("peering://pair?code=042317&secret=abc"))
        assertNull(PairingPayload.secret("peering://pair?code=042317&secret=zz"))
        assertNull(PairingPayload.secret("https://getpeering.app/mac?id=x&secret=0aff"))
    }

    @Test
    fun hostIdRoundTripsThroughHostLink() {
        assertEquals(hostId, PairingPayload.hostId(PairingPayload.hostLink(hostId)))
    }

    @Test
    fun hostIdAcceptsABareUuidWithSurroundingSpace() {
        assertEquals(hostId, PairingPayload.hostId("  $hostId\n"))
    }

    @Test
    fun hostIdIsUppercasedWhateverCaseItArrivesIn() {
        val lower = hostId.lowercase()
        assertEquals(hostId, PairingPayload.hostId(lower))
        assertEquals(hostId, PairingPayload.hostId("https://getpeering.app/mac?id=$lower"))
    }

    @Test
    fun hostIdAcceptsTheWwwHostAndTheOlderScheme() {
        assertEquals(hostId, PairingPayload.hostId("https://www.getpeering.app/mac?id=$hostId"))
        assertEquals(hostId, PairingPayload.hostId("peering://mac?id=$hostId"))
    }

    @Test
    fun sixDigitsAreRefusedAsThePairingCode() {
        assertError(PairingPayloadError.ShortAuthenticationCode) { PairingPayload.hostId("123456") }
        assertError(PairingPayloadError.ShortAuthenticationCode) { PairingPayload.hostId(PairingPayload.codeLink("042317")) }
    }

    @Test
    fun digitsOfAnotherLengthAreNotReadAsThePairingCode() {
        assertError(PairingPayloadError.NotAnIdentifier("12345")) { PairingPayload.hostId("12345") }
        assertError(PairingPayloadError.NotAnIdentifier("1234567")) { PairingPayload.hostId("1234567") }
    }

    @Test
    fun otherSchemesAndHostsAreUnrecognised() {
        assertError(PairingPayloadError.UnrecognisedCode) { PairingPayload.hostId("https://example.com/mac?id=$hostId") }
        assertError(PairingPayloadError.UnrecognisedCode) { PairingPayload.hostId("https://getpeering.app/download?id=$hostId") }
        assertError(PairingPayloadError.UnrecognisedCode) { PairingPayload.hostId("peering://connect") }
        assertError(PairingPayloadError.UnrecognisedCode) { PairingPayload.hostId("WIFI:S:Cafe;T:WPA;P:hunter2;;") }
    }

    @Test
    fun badIdsAreNotIdentifiers() {
        val compact = hostId.replace("-", "")
        assertError(PairingPayloadError.NotAnIdentifier(compact)) { PairingPayload.hostId(compact) }
        assertError(PairingPayloadError.NotAnIdentifier("hello")) { PairingPayload.hostId("peering://mac?id=hello") }
        assertError(PairingPayloadError.NotAnIdentifier("")) { PairingPayload.hostId("peering://mac") }
        assertError(PairingPayloadError.NotAnIdentifier("my mac")) { PairingPayload.hostId("my mac") }
    }

    @Test
    fun emptyInputIsItsOwnError() {
        assertError(PairingPayloadError.EmptyInput) { PairingPayload.hostId("") }
        assertError(PairingPayloadError.EmptyInput) { PairingPayload.hostId("   ") }
    }

    @Test
    fun eachPayloadIsRefusedByTheOtherParser() {
        assertNull(PairingPayload.code(PairingPayload.hostLink(hostId)))
        assertError(PairingPayloadError.ShortAuthenticationCode) { PairingPayload.hostId(PairingPayload.codeLink("042317")) }
    }

    private fun assertError(expected: PairingPayloadError, block: () -> Unit) {
        try {
            block()
            fail("expected $expected")
        } catch (error: PairingPayloadError) {
            assertEquals(expected, error)
        }
    }
}
