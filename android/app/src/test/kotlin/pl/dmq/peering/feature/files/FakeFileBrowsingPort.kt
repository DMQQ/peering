package pl.dmq.peering.feature.files

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteEntryKind

class FakeFileBrowsingPort(initial: FileBrowserState = FileBrowserState()) : FileBrowsingPort {
    val browser = MutableStateFlow(initial)
    val calls = mutableListOf<String>()

    val failed = MutableStateFlow(false)
    val connected = MutableStateFlow(true)

    override val state: StateFlow<FileBrowserState> get() = browser

    override val online: StateFlow<Boolean> get() = connected

    override val destinationFailed: StateFlow<Boolean> get() = failed

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

    override fun download(path: String, destination: String, isFolder: Boolean) {
        calls += "download:$path->$destination${if (isFolder) ":folder" else ""}"
    }

    override fun cancelDownload() {
        calls += "cancelDownload"
    }

    override fun create(name: String, kind: RemoteEntryKind) {
        calls += "create:$name:${kind.name}"
    }

    override fun rename(entry: RemoteDirectoryEntry, to: String) {
        calls += "rename:${entry.name}->$to"
    }

    override fun delete(entries: List<RemoteDirectoryEntry>) {
        calls += "delete:" + entries.joinToString(",") { it.name }
    }

    override fun dismissFailures() {
        calls += "dismissFailures"
    }

    override fun upload(sources: List<String>) {
        calls += "upload:" + sources.joinToString(",")
    }

    override fun cancelUpload() {
        calls += "cancelUpload"
    }
}
