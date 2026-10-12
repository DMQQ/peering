package pl.dmq.peering.ui.wiring

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.files.DownloadSink
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class SessionDownloadsTest {
    private class ThrowingSink(private val failure: Exception) : DownloadSink {
        val discarded = CountDownLatch(1)

        override fun write(bytes: ByteArray) = throw failure

        override fun commit() = throw failure

        override fun discard() {
            discarded.countDown()
            throw failure
        }
    }

    @Test
    fun aProviderThatThrowsAnythingMarksTheDestinationFailed() {
        val failures = listOf(SecurityException("revoked"), IllegalArgumentException("uri"), IOException("io"))
        for (failure in failures) {
            val downloads = SessionDownloads()
            val sink = ThrowingSink(failure)
            downloads.begin(sink)
            downloads.writeRange(0, byteArrayOf(1))
            assertTrue(sink.discarded.await(5, TimeUnit.SECONDS))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (!downloads.destinationFailed.value && System.nanoTime() < deadline) Thread.yield()
            assertTrue(downloads.destinationFailed.value)
            downloads.close()
        }
    }

    @Test
    fun callsAfterCloseAreIgnoredInsteadOfThrowing() {
        val downloads = SessionDownloads()
        downloads.close()
        downloads.writeRange(0, byteArrayOf(1))
        downloads.commit()
        downloads.discard()
        downloads.begin(ThrowingSink(SecurityException()))
        assertEquals(0, downloads.backlog)
    }
}
