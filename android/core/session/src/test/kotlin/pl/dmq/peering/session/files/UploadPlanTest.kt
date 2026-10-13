package pl.dmq.peering.session.files

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest

class UploadPlanTest {
    private val sessionID = "0A1B2C3D-0000-4000-8000-00000000000F"

    private fun pieces(vararg sizes: Int): Iterator<ByteArray> =
        sizes.map { ByteArray(it) { 1 } }.iterator()

    @Test
    fun beginWriteComesFirstWithTheDeclaredSize() {
        val requests = UploadPlan.requests(sessionID, "/a.bin", 5, pieces(5)).toList()
        assertEquals(TerminalRequest.BeginWrite(sessionID, "/a.bin", 5), requests.first())
    }

    @Test
    fun theLastPieceIsTheOneThatReachesTheDeclaredSize() {
        val requests = UploadPlan.requests(sessionID, "/a.bin", 10, pieces(4, 4, 2)).toList().drop(1)
        assertEquals(listOf(false, false, true), requests.map { (it as TerminalRequest.WriteChunk).isLast })
        assertEquals(listOf(4, 4, 2), requests.map { (it as TerminalRequest.WriteChunk).dataBytes.size })
    }

    @Test
    fun anEmptyFileSendsOneEmptyFinalPiece() {
        val requests = UploadPlan.requests(sessionID, "/empty", 0, pieces()).toList()
        assertEquals(
            listOf<TerminalRequest>(
                TerminalRequest.BeginWrite(sessionID, "/empty", 0),
                TerminalRequest.WriteChunk(sessionID, "/empty", "", isLast = true),
            ),
            requests,
        )
    }

    @Test
    fun aFileThatShrankEndsWithAnEmptyFinalPiece() {
        val requests = UploadPlan.requests(sessionID, "/a.bin", 10, pieces(4)).toList()
        assertEquals(TerminalRequest.WriteChunk(sessionID, "/a.bin", "", isLast = true), requests.last())
        assertEquals(3, requests.size)
    }

    @Test
    fun aWroteFileEventIsAWrittenOutcome() {
        val outcome = UploadPlan.outcome(TerminalEvent.WroteFile(sessionID, "/a.bin", 11))
        assertEquals(UploadOutcome.Written("/a.bin", 11), outcome)
    }

    @Test
    fun aWriteFailureEventIsAFailedOutcomeWithTheMacsText() {
        val outcome = UploadPlan.outcome(TerminalEvent.WriteFailure(sessionID, "/a.bin", "Disk full"))
        assertEquals(UploadOutcome.Failed("/a.bin", "Disk full"), outcome)
    }

    @Test
    fun otherEventsAreNoUploadOutcome() {
        assertEquals(null, UploadPlan.outcome(TerminalEvent.Closed(sessionID)))
    }
}
