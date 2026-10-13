package pl.dmq.peering.feature.files

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class DownloadCoordinatorTest {
    private class RecordingSink(private val failAfter: Int? = null) : DownloadSink {
        val written = mutableListOf<ByteArray>()
        var committed = false
        var discarded = 0

        override fun write(bytes: ByteArray) {
            if (failAfter != null && written.size >= failAfter) throw IOException("disk full")
            written += bytes
        }

        override fun commit() {
            committed = true
        }

        override fun discard() {
            discarded++
        }

        fun contents(): ByteArray = written.fold(ByteArray(0)) { all, piece -> all + piece }
    }

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    @Test
    fun piecesInOrderAreWrittenAsTheyArrive() {
        val sink = RecordingSink()
        val coordinator = DownloadCoordinator(sink)
        coordinator.accept(0, bytes(1, 2))
        coordinator.accept(2, bytes(3))
        assertEquals(3L, coordinator.writtenBytes)
        coordinator.complete()
        assertTrue(sink.committed)
        assertArrayEquals(bytes(1, 2, 3), sink.contents())
        assertEquals(DownloadOutcome.Committed, coordinator.outcome)
    }

    @Test
    fun aPieceThatArrivesEarlyWaitsForTheBytesBeforeIt() {
        val sink = RecordingSink()
        val coordinator = DownloadCoordinator(sink)
        coordinator.accept(2, bytes(3, 4))
        assertEquals(0L, coordinator.writtenBytes)
        coordinator.accept(0, bytes(1, 2))
        assertEquals(4L, coordinator.writtenBytes)
        assertArrayEquals(bytes(1, 2, 3, 4), sink.contents())
    }

    @Test
    fun aPieceAlreadyWrittenIsIgnored() {
        val sink = RecordingSink()
        val coordinator = DownloadCoordinator(sink)
        coordinator.accept(0, bytes(1, 2))
        coordinator.accept(0, bytes(9, 9))
        assertArrayEquals(bytes(1, 2), sink.contents())
    }

    @Test
    fun aDownloadWithAGapIsNotCommitted() {
        val sink = RecordingSink()
        val coordinator = DownloadCoordinator(sink)
        coordinator.accept(0, bytes(1))
        coordinator.accept(5, bytes(6))
        coordinator.complete()
        assertTrue(!sink.committed)
        assertEquals(1, sink.discarded)
        assertTrue(coordinator.outcome is DownloadOutcome.Failed)
    }

    @Test
    fun cancelDiscardsWhatWasWrittenOnce() {
        val sink = RecordingSink()
        val coordinator = DownloadCoordinator(sink)
        coordinator.accept(0, bytes(1))
        coordinator.cancel()
        coordinator.cancel()
        coordinator.accept(1, bytes(2))
        coordinator.complete()
        assertEquals(1, sink.discarded)
        assertTrue(!sink.committed)
        assertEquals(DownloadOutcome.Discarded, coordinator.outcome)
    }

    @Test
    fun aWriteFailureDiscardsTheFileAndStopsTheDownload() {
        val sink = RecordingSink(failAfter = 1)
        val coordinator = DownloadCoordinator(sink)
        coordinator.accept(0, bytes(1))
        coordinator.accept(1, bytes(2))
        coordinator.accept(2, bytes(3))
        coordinator.complete()
        assertEquals(1, sink.discarded)
        assertTrue(!sink.committed)
        assertEquals(1L, coordinator.writtenBytes)
        assertEquals(DownloadOutcome.Failed("disk full"), coordinator.outcome)
    }

    @Test
    fun aCommitFailureLeavesNoFile() {
        val sink = object : DownloadSink {
            var discarded = false
            override fun write(bytes: ByteArray) = Unit
            override fun commit() = throw IOException("provider refused")
            override fun discard() {
                discarded = true
            }
        }
        val coordinator = DownloadCoordinator(sink)
        coordinator.accept(0, bytes(1))
        coordinator.complete()
        assertTrue(sink.discarded)
        assertEquals(DownloadOutcome.Failed("provider refused"), coordinator.outcome)
    }

    private class ThrowingSink(private val failure: () -> Exception, private val failing: Set<String>) : DownloadSink {
        var discards = 0

        override fun write(bytes: ByteArray) {
            if ("write" in failing) throw failure()
        }

        override fun commit() {
            if ("commit" in failing) throw failure()
        }

        override fun discard() {
            discards++
            if ("discard" in failing) throw failure()
        }
    }

    private val failures: List<() -> Exception> = listOf(
        { SecurityException("grant revoked") },
        { IllegalArgumentException("bad uri") },
        { IOException("gone") },
    )

    @Test
    fun anyExceptionFromWriteFailsTheDownloadInsteadOfEscaping() {
        for (failure in failures) {
            val sink = ThrowingSink(failure, setOf("write", "discard"))
            val coordinator = DownloadCoordinator(sink)
            coordinator.accept(0, bytes(1))
            assertTrue(coordinator.outcome is DownloadOutcome.Failed)
            assertEquals(1, sink.discards)
        }
    }

    @Test
    fun anyExceptionFromCommitFailsTheDownloadInsteadOfEscaping() {
        for (failure in failures) {
            val sink = ThrowingSink(failure, setOf("commit", "discard"))
            val coordinator = DownloadCoordinator(sink)
            coordinator.complete()
            assertTrue(coordinator.outcome is DownloadOutcome.Failed)
        }
    }

    @Test
    fun aCancelSurvivesADiscardThatThrows() {
        for (failure in failures) {
            val coordinator = DownloadCoordinator(ThrowingSink(failure, setOf("discard")))
            coordinator.cancel()
            assertEquals(DownloadOutcome.Discarded, coordinator.outcome)
        }
    }
}
