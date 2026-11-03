package pl.dmq.peering.platform.net

import java.io.Closeable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SocketCloserTest {
    @Test
    fun theSocketIsClosedOnAnotherThreadThanTheCaller() {
        val closedOn = AtomicReference<Thread>()
        val done = CountDownLatch(1)

        SocketCloser.close(Closeable {
            closedOn.set(Thread.currentThread())
            done.countDown()
        })

        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertNotEquals(Thread.currentThread(), closedOn.get())
    }

    @Test
    fun aSocketThatFailsToCloseDoesNotReachTheCaller() {
        val done = CountDownLatch(1)

        SocketCloser.close(Closeable {
            done.countDown()
            throw java.io.IOException("already gone")
        })

        assertTrue(done.await(5, TimeUnit.SECONDS))
    }
}
