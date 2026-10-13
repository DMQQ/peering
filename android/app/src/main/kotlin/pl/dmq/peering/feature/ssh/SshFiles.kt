package pl.dmq.peering.feature.ssh

import android.content.ContentResolver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.files.FileBrowsingPort
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.ssh.session.LiveServer
import pl.dmq.peering.ssh.session.SshPhase
import pl.dmq.peering.ui.wiring.SessionDownloads
import pl.dmq.peering.ui.wiring.SessionFileBrowsing

/**
 * The file screens over one server's SFTP: the same browser, downloads and uploads that serve a computer, fed by the
 * server's events instead of a computer's. It has a scope of its own so closing the server ends its watchers.
 */
internal class SshFiles(server: LiveServer, resolver: ContentResolver, parent: CoroutineScope) {
    private val scope = CoroutineScope(parent.coroutineContext + SupervisorJob(parent.coroutineContext[Job]))
    private val downloads = SessionDownloads()
    private val browser = FileBrowser(
        supportsFileBrowser = true,
        send = server.session::send,
        writeDownloadRange = downloads::writeRange,
        downloadBacklog = { downloads.backlog },
    )
    private val online = server.session.phase.map { it is SshPhase.Live }
        .stateIn(scope, SharingStarted.Eagerly, server.session.phase.value is SshPhase.Live)

    val port: FileBrowsingPort = SessionFileBrowsing(browser, downloads, resolver, online, scope)

    init {
        server.session.addListener(browser::onEvent)
        scope.launch { downloads.watch(browser) }
    }

    fun close() {
        scope.cancel()
        downloads.close()
    }
}
