package pl.dmq.peering.session.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FileDownloadWindowTest {
    private val chunk = TransferLimits.DOWNLOAD_CHUNK_BYTES.toLong()

    @Test
    fun theFirstPieceIsAskedForBeforeTheSizeIsKnown() {
        val (window, offset) = FileDownloadWindow().first()
        assertEquals(0L, offset)
        assertEquals(1, window.inFlight)
        assertNull(window.fraction)
    }

    @Test
    fun aReceivedPieceKeepsTheWindowFullWithoutPastingTheEnd() {
        val total = chunk * 20
        val (started, _) = FileDownloadWindow().first()
        val (window, offsets) = started.received(chunk.toInt(), total)
        assertEquals((1..TransferLimits.DOWNLOAD_WINDOW).map { it * chunk }, offsets)
        assertEquals(TransferLimits.DOWNLOAD_WINDOW, window.inFlight)
        assertEquals(0.05, window.fraction!!, 1e-9)
    }

    @Test
    fun aSmallFileAsksForNothingMoreOnceItsOnePieceArrives() {
        val (started, _) = FileDownloadWindow().first()
        val (window, offsets) = started.received(100, totalBytes = 100)
        assertTrue(offsets.isEmpty())
        assertTrue(window.isComplete)
        assertEquals(1.0, window.fraction!!, 0.0)
    }

    @Test
    fun aFileIsCompleteOnlyWhenEveryByteHasArrived() {
        val total = chunk * 2
        val (started, _) = FileDownloadWindow().first()
        val (partial, _) = started.received(chunk.toInt(), total)
        assertFalse(partial.isComplete)
    }
}
