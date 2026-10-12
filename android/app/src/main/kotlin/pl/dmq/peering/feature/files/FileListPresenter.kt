package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.wire.RemoteDirectoryEntry

/** The folder on screen: what the browser holds, sorted, with dotfiles left out unless the user asked for them. */
class FileListPresenter(
    private val port: FileBrowsingPort,
    scope: CoroutineScope,
) {
    private val sort = MutableStateFlow(FileSort.NAME)
    private val showsHidden = MutableStateFlow(false)

    val ui: StateFlow<FileListUi> = combine(port.state, sort, showsHidden) { browser, order, hidden ->
        derive(browser, order, hidden)
    }.stateIn(scope, SharingStarted.Eagerly, derive(port.state.value, FileSort.NAME, false))

    fun setSort(order: FileSort) = sort.update { order }

    fun toggleHidden() = showsHidden.update { !it }

    fun open(entry: RemoteDirectoryEntry) = port.openEntry(entry)

    fun up() {
        if (ui.value.canGoUp) port.up()
    }

    fun goTo(path: String) = port.list(path)

    fun refresh() {
        port.list(ui.value.path)
    }

    private fun derive(browser: FileBrowserState, order: FileSort, hidden: Boolean): FileListUi {
        val listing = browser.listing
        val visible = (listing?.entries ?: emptyList())
            .filter { hidden || !it.name.startsWith('.') }
        val entries = order.sorted(visible)
        val status = when {
            browser.browseFailure != null -> FileListStatus.ERROR
            listing == null -> FileListStatus.LOADING
            entries.isEmpty() && !browser.listingLoading -> FileListStatus.EMPTY
            else -> FileListStatus.CONTENT
        }
        return FileListUi(
            status = status,
            path = listing?.path,
            breadcrumbs = listing?.path?.let { FilePath.breadcrumbs(it) } ?: emptyList(),
            entries = entries,
            failure = browser.browseFailure,
            isTruncated = listing?.isTruncated == true,
            isRefreshing = browser.listingLoading && listing != null,
            canGoUp = listing?.parentPath != null,
            sort = order,
            showsHidden = hidden,
        )
    }
}
