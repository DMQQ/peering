package pl.dmq.peering.feature.agents

import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.agents.preview.PreviewReply
import pl.dmq.peering.feature.agents.preview.PreviewShield
import pl.dmq.peering.wire.PreviewHeader

class PreviewShieldTest {
    @Test
    fun aProxiedPageCarriesThePolicyThatRefusesSockets() {
        val reply = PreviewReply.from(200, listOf(PreviewHeader("Content-Type", "text/html")), ByteArrayInputStream(ByteArray(0)))

        val policy = reply.headers.getValue(PreviewShield.POLICY_HEADER)
        assertTrue(policy.startsWith("connect-src http: https:"))
        assertFalse(policy.contains("ws"))
        assertFalse(policy.contains("'self'"))
    }

    @Test
    fun aPolicyThePageSentIsKeptAlongsideOurs() {
        val reply = PreviewReply.from(200, listOf(PreviewHeader("content-security-policy", "img-src 'none'")), ByteArrayInputStream(ByteArray(0)))

        assertEquals("img-src 'none', ${PreviewShield.POLICY}", reply.headers.getValue("content-security-policy"))
        assertEquals(1, reply.headers.keys.count { it.equals(PreviewShield.POLICY_HEADER, ignoreCase = true) })
    }

    @Test
    fun theScriptRemovesEveryConstructorThatSkipsInterception() {
        val script = PreviewShield.documentStartScript
        for (name in listOf("WebSocket", "WebTransport", "RTCPeerConnection", "webkitRTCPeerConnection", "serviceWorker")) {
            assertTrue(name, script.contains("\"$name\""))
        }
    }
}
