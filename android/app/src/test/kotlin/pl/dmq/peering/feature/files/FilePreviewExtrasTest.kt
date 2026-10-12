package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.session.files.FilePreview
import pl.dmq.peering.wire.RemoteFileKind

class FilePreviewExtrasTest {
    private fun presenter(port: FakeFileBrowsingPort) = FilePreviewPresenter(port, CoroutineScope(UnconfinedTestDispatcher()))

    private fun port(path: String, kind: RemoteFileKind, bytes: ByteArray, total: Long = bytes.size.toLong()) =
        FakeFileBrowsingPort(FileBrowserState(preview = FilePreview(path, kind, bytes, total, isComplete = true)))

    @Test
    fun aMarkdownFileIsRenderedAsBlocks() = runTest {
        val ui = presenter(port("/a/README.md", RemoteFileKind.TEXT, "# Hi\n\n- one".toByteArray())).ui.value!!
        val content = ui.content as PreviewContent.Markdown
        assertEquals(listOf(MarkdownBlock.Heading(1, "Hi"), MarkdownBlock.Bullet("one", 0)), content.blocks)
    }

    @Test
    fun anEmptyTextFileSaysSo() = runTest {
        assertEquals(PreviewContent.Empty, presenter(port("/a/x.txt", RemoteFileKind.TEXT, ByteArray(0))).ui.value!!.content)
    }

    @Test
    fun codeShowsLineNumbersAndScrollsWhileProseWraps() = runTest {
        val code = presenter(port("/a/Main.kt", RemoteFileKind.TEXT, "val x = 1".toByteArray())).ui.value!!
        assertFalse(code.wraps)
        assertTrue((code.content as PreviewContent.Text).showsLineNumbers)
        val prose = presenter(port("/a/notes.txt", RemoteFileKind.TEXT, "hello".toByteArray())).ui.value!!
        assertTrue(prose.wraps)
        assertFalse((prose.content as PreviewContent.Text).showsLineNumbers)
    }

    @Test
    fun theWrapChoiceIsKeptForTheOpenFile() = runTest {
        val presenter = presenter(port("/a/Main.kt", RemoteFileKind.TEXT, "val x = 1".toByteArray()))
        presenter.toggleWrap()
        assertTrue(presenter.ui.value!!.wraps)
        presenter.toggleWrap()
        assertFalse(presenter.ui.value!!.wraps)
    }

    @Test
    fun aPictureCutAtTheCapIsTooLargeToDraw() = runTest {
        val cut = port("/a/big.png", RemoteFileKind.IMAGE, ByteArray(10), total = 20_000_000)
        assertEquals(PreviewContent.TooLarge(20_000_000), presenter(cut).ui.value!!.content)
    }

    @Test
    fun shareHandsOverTheWholeFileOnceAndOnlyWhenComplete() = runTest {
        val presenter = presenter(port("/a/b.txt", RemoteFileKind.TEXT, "hi".toByteArray()))
        presenter.share()
        val request = presenter.shareRequest.value!!
        assertEquals("b.txt", request.name)
        assertEquals("text/plain", request.mimeType)
        presenter.shareHandled()
        assertNull(presenter.shareRequest.value)

        val cut = presenter(port("/a/c.txt", RemoteFileKind.TEXT, "hi".toByteArray(), total = 99))
        assertFalse(cut.ui.value!!.canShare)
        cut.share()
        assertNull(cut.shareRequest.value)
    }
}
