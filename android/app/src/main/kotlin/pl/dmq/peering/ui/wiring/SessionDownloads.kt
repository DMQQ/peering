package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.files.DownloadCoordinator
import pl.dmq.peering.feature.files.DownloadOutcome
import pl.dmq.peering.feature.files.DownloadSink
import pl.dmq.peering.session.controller.DownloadWriter
import pl.dmq.peering.session.files.FileBrowser
import pl.dmq.peering.session.files.FileTransfer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * The bytes of the session's downloads, written in arrival order on one background thread. The coordinator is touched
 * only on that thread; the flags other threads read are state flows.
 */
internal class SessionDownloads : DownloadWriter {
    private val writer: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "peering-downloads").apply { isDaemon = true }
    }
    private var coordinator: DownloadCoordinator? = null
    private val mutableDestinationFailed = MutableStateFlow(false)
    private val pending = AtomicInteger(0)
    private val caughtUp = Channel<Unit>(Channel.CONFLATED)

    override val backlog: Int get() = pending.get()

    /** True once the chosen destination could not be opened or written; the download it belonged to has ended. */
    val destinationFailed: StateFlow<Boolean> = mutableDestinationFailed.asStateFlow()

    /** Routes the next download's bytes to [sink]. Call it before the request for the download is sent. */
    fun begin(sink: DownloadSink) {
        mutableDestinationFailed.value = false
        writer.execute { coordinator = DownloadCoordinator(sink) }
    }

    /** The user picked no destination, or it could not be opened, so the download does not start. */
    fun refuse() {
        mutableDestinationFailed.value = true
    }

    override fun writeRange(offset: Long, bytes: ByteArray) {
        pending.incrementAndGet()
        writer.execute {
            try {
                settle { accept(offset, bytes) }
            } finally {
                pending.decrementAndGet()
                caughtUp.trySend(Unit)
            }
        }
    }

    fun commit() = writer.execute { settle { complete() } }

    fun discard() = writer.execute { settle { cancel() } }

    /** Ends the writer after the work already queued. */
    fun close() = writer.shutdown()

    /**
     * Ends the downloads the browser reports: a finished transfer is committed, a failed one or a destination that
     * failed mid-write is discarded and the Mac's transfer is stopped.
     */
    suspend fun watch(browser: FileBrowser) = coroutineScope {
        launch {
            for (signal in caughtUp) browser.resumeDownload()
        }
        launch {
            destinationFailed.filter { it }.collect {
                browser.cancelDownload()
                discard()
            }
        }
        browser.state.map { it.transfer }.distinctUntilChanged().collect { transfer ->
            when (transfer) {
                is FileTransfer.Finished -> commit()
                is FileTransfer.Failed -> discard()
                else -> Unit
            }
        }
    }

    private fun settle(action: DownloadCoordinator.() -> Unit) {
        val current = coordinator ?: return
        current.action()
        val outcome = current.outcome ?: return
        if (outcome is DownloadOutcome.Failed) mutableDestinationFailed.value = true
        coordinator = null
    }
}
