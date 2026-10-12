package pl.dmq.peering.session.controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException

class ConnectFailureKindTest {
    @Test
    fun aRefusalIsRefused() = assertEquals(ConnectFailureKind.Refused, ConnectFailureKind.of(ConnectException("refused")))

    @Test
    fun aTlsErrorWrappedInAnotherExceptionIsStillTls() =
        assertEquals(ConnectFailureKind.TlsFailed, ConnectFailureKind.of(IOException("io", SSLHandshakeException("bad"))))

    @Test
    fun aSlowHostIsATimeout() = assertEquals(ConnectFailureKind.Timeout, ConnectFailureKind.of(SocketTimeoutException()))

    @Test
    fun anythingElseIsUnreachable() = assertEquals(ConnectFailureKind.Unreachable, ConnectFailureKind.of(UnknownHostException("x")))

    @Test
    fun theDescriptionNamesTheClassTheMessageAndTheRootCause() {
        val text = ConnectFailureKind.describe(IOException("outer", ConnectException("refused")))

        assertEquals("IOException: outer (caused by ConnectException: refused)", text)
    }

    @Test
    fun aLongMessageIsCut() {
        assertTrue(ConnectFailureKind.describe(IOException("x".repeat(1000))).length <= 300)
    }
}
