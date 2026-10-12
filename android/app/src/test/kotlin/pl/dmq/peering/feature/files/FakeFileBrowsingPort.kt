package pl.dmq.peering.feature.files

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.wire.RemoteDirectoryEntry

class FakeFileBrowsingPort(initial: FileBrowserState = FileBrowserState()) : FileBrowsingPort {
    val browser = MutableStateFlow(initial)
    val calls = mutableListOf<String>()

    override val state: StateFlow<FileBrowserState> get() = browser

    override fun open(initialPath: String?) {
        calls += "open:$initialPath"
    }

    override fun list(path: String?) {
        calls += "list:$path"
    }

    override fun openEntry(entry: RemoteDirectoryEntry) {
        calls += "openEntry:${entry.name}"
    }

    override fun up() {
        calls += "up"
    }

    override fun preview(path: String) {
        calls += "preview:$path"
    }

    override fun closePreview() {
        calls += "closePreview"
    }

    override fun download(path: String) {
        calls += "download:$path"
    }

    override fun downloadFolder(path: String) {
        calls += "downloadFolder:$path"
    }

    override fun cancelDownload() {
        calls += "cancelDownload"
    }
}
