package pl.dmq.peering.ui.wiring

import android.content.ContentResolver
import android.net.Uri
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.files.FileBrowsingPort
import pl.dmq.peering.feature.files.InputChunks
import pl.dmq.peering.feature.files.ShellActions
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.session.files.FileUpload
import pl.dmq.peering.session.files.ShellPath
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.files.TransferLimits
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteEntryKind
import java.io.IOException

/**
 * The file screens over the session's browser, with downloads written to the document the user picked and uploads
 * read from the documents they chose. Uploads run on [scope] in the order given.
 */
internal class SessionFileBrowsing(
    private val browser: FileBrowser,
    private val downloads: SessionDownloads,
    private val resolver: ContentResolver,
    override val online: StateFlow<Boolean>,
    private val scope: CoroutineScope,
    private val terminals: TerminalSessions? = null,
) : FileBrowsingPort {
    private var uploading: Job? = null

    override val shell: ShellActions? = terminals?.let { sessions ->
        object : ShellActions {
            override val ready: StateFlow<Boolean> = sessions.state
                .map { state -> state.tabs.firstOrNull { it.id == state.selectedID }?.isRunning == true }
                .stateIn(scope, SharingStarted.Eagerly, false)

            override fun putPath(path: String) {
                sessions.state.value.selectedID?.let { sessions.input(it, ShellPath.quoted(path)) }
            }

            override fun run(path: String) = sessions.runInNewTerminal(ShellPath.runCommand(path))
        }
    }

    override val state: StateFlow<FileBrowserState> get() = browser.state

    override val destinationFailed: StateFlow<Boolean> get() = downloads.destinationFailed

    override fun open(initialPath: String?) = browser.open(initialPath)

    override fun list(path: String?) = browser.list(path)

    override fun openEntry(entry: RemoteDirectoryEntry) = browser.openEntry(entry)

    override fun up() = browser.up()

    override fun preview(path: String) = browser.preview(path)

    override fun closePreview() = browser.closePreview()

    override fun download(path: String, destination: String, isFolder: Boolean) {
        val sink = try {
            SafDownloadSink.open(resolver, Uri.parse(destination))
        } catch (failure: IOException) {
            return downloads.refuse()
        } catch (failure: SecurityException) {
            return downloads.refuse()
        }
        downloads.begin(sink)
        if (isFolder) browser.downloadFolder(path) else browser.download(path)
    }

    override fun cancelDownload() {
        browser.cancelDownload()
        downloads.discard()
    }

    override fun create(name: String, kind: RemoteEntryKind) = browser.create(name, kind)

    override fun rename(entry: RemoteDirectoryEntry, to: String) = browser.rename(entry, to)

    override fun delete(entries: List<RemoteDirectoryEntry>) = browser.delete(entries)

    override fun dismissFailures() = browser.dismissFailures()

    override fun upload(sources: List<String>) {
        val previous = uploading
        uploading = scope.launch(Dispatchers.IO) {
            // An upload that is not running any more is finished or stuck on a provider, and must not hold this one back.
            if (browser.state.value.upload is FileUpload.Running) previous?.join() else previous?.cancel()
            for (source in sources) {
                if (!send(Uri.parse(source))) break
            }
        }
    }

    override fun cancelUpload() {
        browser.cancelUpload()
        uploading?.cancel()
    }

    private suspend fun send(uri: Uri): Boolean {
        var name = uri.lastPathSegment.orEmpty()
        try {
            val document = SafUploadSource.query(resolver, uri)
            if (document == null) {
                browser.reportUnreadable(name)
                return false
            }
            name = document.name
            document.open().use { input ->
                browser.upload(document.name, document.size, InputChunks(input, TransferLimits.UPLOAD_CHUNK_BYTES))
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            // A revoked grant throws SecurityException, which is not an IOException and would end the app's scope.
            browser.reportUnreadable(name)
            return false
        }
        return browser.state.value.upload is FileUpload.Done
    }
}
