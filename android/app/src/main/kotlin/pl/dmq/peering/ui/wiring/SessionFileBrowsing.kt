package pl.dmq.peering.ui.wiring

import android.content.ContentResolver
import android.net.Uri
import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.feature.files.FileBrowsingPort
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.wire.RemoteDirectoryEntry
import java.io.IOException

/** The file screens over the session's browser, with downloads written to the document the user picked. */
internal class SessionFileBrowsing(
    private val browser: FileBrowser,
    private val downloads: SessionDownloads,
    private val resolver: ContentResolver,
) : FileBrowsingPort {
    override val state: StateFlow<FileBrowserState> get() = browser.state

    override val destinationFailed: StateFlow<Boolean> get() = downloads.destinationFailed

    override fun open(initialPath: String?) = browser.open(initialPath)

    override fun list(path: String?) = browser.list(path)

    override fun openEntry(entry: RemoteDirectoryEntry) = browser.openEntry(entry)

    override fun up() = browser.up()

    override fun preview(path: String) = browser.preview(path)

    override fun closePreview() = browser.closePreview()

    override fun download(path: String, destination: String) {
        val sink = try {
            SafDownloadSink.open(resolver, Uri.parse(destination))
        } catch (failure: IOException) {
            return downloads.refuse()
        } catch (failure: SecurityException) {
            return downloads.refuse()
        }
        downloads.begin(sink)
        browser.download(path)
    }

    override fun cancelDownload() {
        browser.cancelDownload()
        downloads.discard()
    }
}
