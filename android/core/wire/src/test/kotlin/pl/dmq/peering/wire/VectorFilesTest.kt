package pl.dmq.peering.wire

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

class VectorFilesTest {
    @Test
    fun theSharedCryptoVectorsAreReadable() {
        val code = VectorFiles.load("crypto.json").jsonObject["sas"]!!.jsonObject["code"]!!.jsonPrimitive.content
        assertEquals("365357", code)
    }

    @Test
    fun theProtocolVersionIsTwenty() {
        assertEquals(20, PROTOCOL_VERSION)
    }
}
