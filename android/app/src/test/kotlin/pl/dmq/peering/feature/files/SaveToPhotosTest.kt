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

class SaveToPhotosTest {
    private fun port(path: String, kind: RemoteFileKind, bytes: ByteArray, total: Long = bytes.size.toLong()) =
        FakeFileBrowsingPort(FileBrowserState(preview = FilePreview(path, kind, bytes, total, isComplete = true)))

    private val gallery = FakeGalleryWriter()

    private fun presenter(port: FakeFileBrowsingPort, writer: GalleryWriter = gallery) =
        FilePreviewPresenter(port, CoroutineScope(UnconfinedTestDispatcher()), writer)

    @Test
    fun picturesGoToPicturesAndVideosToMoviesWithTheirMediaType() {
        assertEquals(GalleryTarget("a.jpg", "image/jpeg", isVideo = false), GalleryTarget.of("/x/a.jpg"))
        assertEquals("Pictures/Peering", GalleryTarget.of("/x/a.PNG")?.relativePath)
        val clip = GalleryTarget.of("/x/clip.mov")
        assertEquals("video/quicktime", clip?.mimeType)
        assertEquals("Movies/Peering", clip?.relativePath)
    }

    @Test
    fun filesTheGalleryDoesNotShowHaveNoTarget() {
        assertNull(GalleryTarget.of("/x/logo.svg"))
        assertNull(GalleryTarget.of("/x/notes.txt"))
    }

    @Test
    fun aWholePictureIsSavedFromThePreviewWithoutDownloadingAgain() = runTest {
        val port = port("/a/photo.png", RemoteFileKind.IMAGE, byteArrayOf(1, 2, 3))
        val presenter = presenter(port)
        assertTrue(presenter.ui.value!!.canSaveToPhotos)

        presenter.saveToPhotos()

        assertEquals(listOf("write photo.png 3", "report true"), gallery.calls)
        assertFalse(port.calls.any { it.startsWith("download") })
    }

    @Test
    fun eachTapSavesOnceAndNothingIsLeftToReplay() = runTest {
        val presenter = presenter(port("/a/photo.png", RemoteFileKind.IMAGE, byteArrayOf(1, 2, 3)))

        presenter.saveToPhotos()
        presenter.saveToPhotos()

        assertEquals(2, gallery.calls.count { it.startsWith("write") })
    }

    @Test
    fun aVideoDownloadsIntoTheReservedGalleryItem() = runTest {
        val port = port("/a/clip.mp4", RemoteFileKind.VIDEO, ByteArray(0), total = 5_000_000)

        presenter(port).saveToPhotos()

        assertEquals(listOf("reserve clip.mp4"), gallery.calls)
        assertTrue("download:/a/clip.mp4->content://media/external/video/media/7" in port.calls)
    }

    @Test
    fun aGalleryThatRefusesAnItemReportsFailureAndDownloadsNothing() = runTest {
        val refusing = FakeGalleryWriter(reserves = null)
        val port = port("/a/clip.mp4", RemoteFileKind.VIDEO, ByteArray(0), total = 5_000_000)

        presenter(port, refusing).saveToPhotos()

        assertEquals(listOf("reserve clip.mp4", "report false"), refusing.calls)
        assertFalse(port.calls.any { it.startsWith("download") })
    }

    @Test
    fun aPictureCutAtTheCapDownloadsInstead() = runTest {
        presenter(port("/a/big.jpg", RemoteFileKind.IMAGE, ByteArray(10), total = 20_000_000)).saveToPhotos()
        assertEquals(listOf("reserve big.jpg"), gallery.calls)
    }

    @Test
    fun aTextFileOffersNoSave() = runTest {
        assertFalse(presenter(port("/a/b.txt", RemoteFileKind.TEXT, "hi".toByteArray())).ui.value!!.canSaveToPhotos)
    }
}
