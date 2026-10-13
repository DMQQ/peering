package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.files.DownloadFailure
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.session.files.FileDownloadPlan
import pl.dmq.peering.session.files.FilePreview
import pl.dmq.peering.session.files.FileTransfer
import pl.dmq.peering.wire.RemoteFileKind

class FilePreviewPresenterTest {
    private fun presenter(port: FakeFileBrowsingPort) =
        FilePreviewPresenter(port, CoroutineScope(UnconfinedTestDispatcher()))

    private fun preview(
        kind: RemoteFileKind?,
        contents: ByteArray = ByteArray(0),
        total: Long? = null,
        complete: Boolean = false,
        failure: String? = null,
    ) = FilePreview("/a/f", kind, contents, total, complete, failure)

    private fun port(preview: FilePreview?, transfer: FileTransfer = FileTransfer.Idle) =
        FakeFileBrowsingPort(FileBrowserState(preview = preview, transfer = transfer))

    @Test
    fun noPreviewMeansNothingToShow() = runTest {
        assertNull(presenter(port(null)).ui.value)
    }

    @Test
    fun textWaitsForEveryByteBeforeItIsShown() = runTest {
        val partial = preview(RemoteFileKind.TEXT, "hel".toByteArray(), total = 10)
        val content = presenter(port(partial)).ui.value!!.content
        assertEquals(PreviewContent.Loading(0.3), content)
    }

    @Test
    fun completeTextIsShownLineByLine() = runTest {
        val done = preview(RemoteFileKind.TEXT, "a\nb".toByteArray(), total = 3, complete = true)
        val content = presenter(port(done)).ui.value!!.content as PreviewContent.Text
        assertEquals(listOf("a", "b"), content.lines)
        assertTrue(!content.isTruncated)
    }

    @Test
    fun aTextPreviewCutAtTheLimitSaysSo() = runTest {
        val cut = FilePreview("/a/f", RemoteFileKind.TEXT, "head".toByteArray(), 9_000_000, isComplete = true)
        val content = presenter(port(cut)).ui.value!!.content as PreviewContent.Text
        assertTrue(content.isTruncated)
        assertEquals(4L, content.shownBytes)
        assertEquals(9_000_000L, content.totalBytes)
    }

    @Test
    fun textThatIsNotUtf8IsUnsupportedNotGarbled() = runTest {
        val binary = preview(RemoteFileKind.TEXT, byteArrayOf(0xFF.toByte()), total = 1, complete = true)
        assertEquals(PreviewContent.Unsupported(RemoteFileKind.TEXT), presenter(port(binary)).ui.value!!.content)
    }

    @Test
    fun aPictureIsHandedOverAsItsBytes() = runTest {
        val picture = preview(RemoteFileKind.IMAGE, byteArrayOf(1, 2, 3), total = 3, complete = true)
        val content = presenter(port(picture)).ui.value!!.content as PreviewContent.Image
        assertEquals(listOf<Byte>(1, 2, 3), content.bytes.toList())
    }

    @Test
    fun videosAndSvgsAreUnsupportedWithTheirKindKept() = runTest {
        val video = preview(RemoteFileKind.VIDEO, total = 1, complete = true)
        assertEquals(PreviewContent.Unsupported(RemoteFileKind.VIDEO), presenter(port(video)).ui.value!!.content)
        val svg = preview(RemoteFileKind.SVG, total = 1, complete = true)
        assertEquals(PreviewContent.Unsupported(RemoteFileKind.SVG), presenter(port(svg)).ui.value!!.content)
    }

    @Test
    fun aFailedReadShowsTheMacsMessage() = runTest {
        val failed = preview(RemoteFileKind.TEXT, failure = "Cannot read")
        assertEquals(PreviewContent.Failed("Cannot read"), presenter(port(failed)).ui.value!!.content)
    }

    @Test
    fun downloadForThisFileIsShownAsItRuns() = runTest {
        val plan = FileDownloadPlan(sessionID = "b", sourcePath = "/a/f", isFolder = false, readPath = "/a/f")
        val p = port(preview(RemoteFileKind.PDF, total = 1, complete = true), FileTransfer.Running(plan))
        assertEquals(DownloadStatus.Running(fraction = null, isZipping = false, sourcePath = "/a/f"), presenter(p).ui.value!!.download)
    }

    @Test
    fun aDownloadOfAnotherFileIsNotShownHere() = runTest {
        val plan = FileDownloadPlan(sessionID = "b", sourcePath = "/other", isFolder = false, readPath = "/other")
        val p = port(preview(RemoteFileKind.PDF, total = 1, complete = true), FileTransfer.Running(plan))
        assertEquals(DownloadStatus.Idle, presenter(p).ui.value!!.download)
    }

    @Test
    fun aFinishedAndAFailedDownloadAreReported() = runTest {
        val finished = port(preview(RemoteFileKind.PDF, total = 1, complete = true), FileTransfer.Finished("/a/f"))
        assertEquals(DownloadStatus.Finished, presenter(finished).ui.value!!.download)
        val failed = port(
            preview(RemoteFileKind.PDF, total = 1, complete = true),
            FileTransfer.Failed("/a/f", DownloadFailure.Transfer("Disk full")),
        )
        assertEquals(DownloadStatus.Failed(DownloadProblem.Transfer("Disk full")), presenter(failed).ui.value!!.download)
    }

    @Test
    fun aDownloadAsksForADestinationBeforeItStarts() = runTest {
        val p = port(preview(RemoteFileKind.PDF, total = 1, complete = true))
        val presenter = presenter(p)
        presenter.download()
        assertEquals("/a/f", presenter.destinationRequest.value)
        assertEquals(emptyList<String>(), p.calls)
        presenter.destinationChosen("content://picked")
        assertNull(presenter.destinationRequest.value)
        assertEquals(listOf("download:/a/f->content://picked"), p.calls)
    }

    @Test
    fun aPickerThatIsDismissedStartsNothing() = runTest {
        val p = port(preview(RemoteFileKind.PDF, total = 1, complete = true))
        val presenter = presenter(p)
        presenter.download()
        presenter.destinationChosen(null)
        assertNull(presenter.destinationRequest.value)
        assertEquals(emptyList<String>(), p.calls)
    }

    @Test
    fun aDestinationThatCannotBeWrittenIsReportedOnThisFile() = runTest {
        val p = port(preview(RemoteFileKind.PDF, total = 1, complete = true))
        val presenter = presenter(p)
        presenter.download()
        presenter.destinationChosen("content://picked")
        p.failed.value = true
        assertEquals(DownloadStatus.Failed(DownloadProblem.Destination), presenter.ui.value!!.download)
    }

    @Test
    fun cancelAndCloseGoThroughThePort() = runTest {
        val p = port(preview(RemoteFileKind.PDF, total = 1, complete = true))
        val presenter = presenter(p)
        presenter.cancelDownload()
        presenter.close()
        assertEquals(listOf("cancelDownload", "closePreview"), p.calls)
    }

    @Test
    fun aPdfSentWholeIsDrawnAndOneCutAtTheLimitSaysItIsTooLarge() = runTest {
        val whole = preview(RemoteFileKind.PDF, "%PDF".toByteArray(), total = 4, complete = true)
        val content = presenter(port(whole)).ui.value!!.content as PreviewContent.Pdf
        assertEquals("%PDF", String(content.bytes))

        val cut = FilePreview("/a/f", RemoteFileKind.PDF, "%PDF".toByteArray(), 90_000_000, isComplete = true)
        assertEquals(PreviewContent.TooLarge(90_000_000), presenter(port(cut)).ui.value!!.content)
    }

    @Test
    fun aPdfPageIsDrawnAtItsOwnShapeAndHeldToAHeightABitmapCanHave() {
        assertEquals(1_100, PdfPageSize.heightFor(widthPx = 850, pageWidth = 612, pageHeight = 792))
        assertEquals(8_192, PdfPageSize.heightFor(widthPx = 1_000, pageWidth = 100, pageHeight = 100_000))
        assertEquals(500, PdfPageSize.heightFor(widthPx = 500, pageWidth = 0, pageHeight = 0))
    }
}
