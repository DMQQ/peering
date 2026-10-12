package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.feature.files.FileBrowsingPort
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.wire.RemoteDirectoryEntry

/**
 * The file screens over the session's browser. Downloads are not forwarded: the bytes would need a destination on the
 * phone, and none is chosen yet, so those calls do nothing rather than start a transfer that cannot be kept.
 */
internal class SessionFileBrowsing(private val browser: FileBrowser) : FileBrowsingPort {
    override val state: StateFlow<FileBrowserState> get() = browser.state

    override fun open(initialPath: String?) = browser.open(initialPath)

    override fun list(path: String?) = browser.list(path)

    override fun openEntry(entry: RemoteDirectoryEntry) = browser.openEntry(entry)

    override fun up() = browser.up()

    override fun preview(path: String) = browser.preview(path)

    override fun closePreview() = browser.closePreview()

    override fun download(path: String) = Unit

    override fun downloadFolder(path: String) = Unit

    override fun cancelDownload() = browser.cancelDownload()
}
