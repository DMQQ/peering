package pl.dmq.peering.session.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.TerminalRequest

class FileDownloadPlanTest {
    private val sessionID = "0A1B2C3D-0000-4000-8000-00000000000F"
    private val chunk = TransferLimits.DOWNLOAD_CHUNK_BYTES.toLong()

    private fun fileDownload() = FileDownloadPlan(sessionID, "/a.bin", isFolder = false, readPath = "/a.bin")

    @Test
    fun aFileStartsWithARangeReadFromZero() {
        val (plan, request) = fileDownload().start()
        assertEquals(TerminalRequest.ReadRange(sessionID, "/a.bin", 0), request)
        assertEquals(false, plan.isZipping)
    }

    @Test
    fun aFolderStartsByAskingTheMacToZipIt() {
        val folder = FileDownloadPlan(sessionID, "/Projects", isFolder = true, readPath = null)
        val (plan, request) = folder.start()
        assertEquals(TerminalRequest.ArchiveFolder(sessionID, "/Projects"), request)
        assertTrue(plan.isZipping)
    }

    @Test
    fun theZipIsReadOnceItIsReady() {
        val folder = FileDownloadPlan(sessionID, "/Projects", isFolder = true, readPath = null)
        val step = folder.onArchiveReady("/Projects", "/tmp/Projects.zip")
        val continued = step as DownloadStep.Continue
        assertEquals("/tmp/Projects.zip", continued.plan.readPath)
        assertEquals(listOf<TerminalRequest>(TerminalRequest.ReadRange(sessionID, "/tmp/Projects.zip", 0)), continued.requests)
    }

    @Test
    fun aZipForAnotherFolderIsIgnored() {
        val folder = FileDownloadPlan(sessionID, "/Projects", isFolder = true, readPath = null)
        assertEquals(DownloadStep.Ignored, folder.onArchiveReady("/Other", "/tmp/Other.zip"))
    }

    @Test
    fun aPieceAtItsOffsetAsksForTheNextAndTheLastOneCompletes() {
        val total = chunk * 2
        val (started, _) = fileDownload().start()
        val afterFirst = started.onFileRange("/a.bin", 0, total, chunk.toInt()) as DownloadStep.Continue
        assertEquals(listOf<TerminalRequest>(TerminalRequest.ReadRange(sessionID, "/a.bin", chunk)), afterFirst.requests)

        val done = afterFirst.plan.onFileRange("/a.bin", chunk, total, chunk.toInt())
        assertTrue(done is DownloadStep.Complete)
    }

    @Test
    fun pieceForAnotherPathIsIgnored() {
        assertEquals(DownloadStep.Ignored, fileDownload().onFileRange("/b.bin", 0, 10, 10))
    }

    @Test
    fun aFileOverTheLimitIsRefusedBeforeAnyPieceIsAsked() {
        val step = fileDownload().onFileRange("/a.bin", 0, TransferLimits.MAXIMUM_DOWNLOAD_BYTES + 1, 10)
        assertEquals(DownloadStep.Failed(DownloadFailure.TooLarge), step)
    }

    @Test
    fun anEmptyPieceBeforeTheDeclaredSizeIsAShortRead() {
        val (started, _) = fileDownload().start()
        val step = started.onFileRange("/a.bin", 0, totalBytes = 100, byteCount = 0)
        assertEquals(DownloadStep.Failed(DownloadFailure.ShortRead), step)
    }

    @Test
    fun aTransferFailureForTheSourceOrTheZipEndsTheDownload() {
        assertEquals(
            DownloadStep.Failed(DownloadFailure.Transfer("Denied")),
            fileDownload().onTransferFailure("/a.bin", "Denied"),
        )
        assertEquals(DownloadStep.Ignored, fileDownload().onTransferFailure("/other", "Denied"))
    }
}
