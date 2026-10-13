package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.session.files.FilePath

/** What the folder picker shows: the folders of one directory, and the directory itself as the choice. */
data class FolderPickerUi(
    val status: FileListStatus,
    val path: String?,
    val breadcrumbs: List<FilePath.Breadcrumb>,
    val folders: List<String>,
    val failure: String?,
    val canGoUp: Boolean,
)

/**
 * A folder chooser over the file browser, for any screen that needs a path on the computer (the Agents hub picks a
 * project with it). It lists folders only, walks the tree with [enter], [up] and [goTo], and offers the folder on
 * screen as the choice through [chosenPath]. It drives the same browser as the Files screen, so that screen
 * resumes in whichever folder the picker left.
 */
class FolderPickerPresenter(
    private val port: FileBrowsingPort,
    scope: CoroutineScope,
) {
    val ui: StateFlow<FolderPickerUi> = combine(port.state, port.online) { browser, online -> derive(browser, online) }
        .stateIn(scope, SharingStarted.Eagerly, derive(port.state.value, port.online.value))

    /** Starts at [initialPath], or at the computer's home folder when it is null. */
    fun open(initialPath: String? = null) = port.open(initialPath)

    fun enter(folderName: String) {
        val path = ui.value.path ?: return
        port.list(FilePath.child(path, folderName))
    }

    fun goTo(path: String) = port.list(path)

    fun up(): Boolean {
        if (!ui.value.canGoUp) return false
        port.up()
        return true
    }

    fun refresh() = port.list(ui.value.path)

    /** The folder on screen, which is what "use this folder" returns, or null before a listing arrives. */
    fun chosenPath(): String? = ui.value.path

    private fun derive(browser: FileBrowserState, online: Boolean): FolderPickerUi {
        val listing = browser.listing
        val folders = listing?.entries.orEmpty()
            .filter { it.isDirectory && !it.name.startsWith('.') }
            .map { it.name }
            .sortedBy { it.lowercase() }
        val status = when {
            browser.browseFailure != null -> FileListStatus.ERROR
            listing == null && !online -> FileListStatus.OFFLINE
            listing == null -> FileListStatus.LOADING
            folders.isEmpty() && !browser.listingLoading -> FileListStatus.EMPTY
            else -> FileListStatus.CONTENT
        }
        return FolderPickerUi(
            status = status,
            path = listing?.path,
            breadcrumbs = listing?.path?.let(FilePath::breadcrumbs).orEmpty(),
            folders = folders,
            failure = browser.browseFailure,
            canGoUp = listing?.parentPath != null,
        )
    }
}
