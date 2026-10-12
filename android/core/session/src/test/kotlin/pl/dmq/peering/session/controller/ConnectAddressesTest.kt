package pl.dmq.peering.session.controller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.PeerAddress
import java.net.ConnectException
import java.net.SocketTimeoutException

class ConnectAddressesTest {
    @Test
    fun aStalePortFallsBackToTheDefaultOnTheSameHost() {
        assertEquals(
            listOf(PeerAddress("10.0.0.2", 51599), PeerAddress("10.0.0.2", 51515)),
            ConnectAddresses.candidates(PeerAddress("10.0.0.2", 51599)),
        )
    }

    @Test
    fun theDefaultPortIsTriedOnce() {
        assertEquals(listOf(PeerAddress("10.0.0.2", 51515)), ConnectAddresses.candidates(PeerAddress("10.0.0.2", 51515)))
    }

    @Test
    fun aRefusalIsRecognisedThroughItsWrappers() {
        assertTrue(ConnectAddresses.refused(RuntimeException("tls", ConnectException("refused"))))
        assertFalse(ConnectAddresses.refused(SocketTimeoutException("slow")))
    }
}
