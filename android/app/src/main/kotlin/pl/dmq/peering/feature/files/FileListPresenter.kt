package pl.dmq.peering.feature.files

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.session.files.FileBrowserState
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.session.files.RemoteFileName
import pl.dmq.peering.wire.RemoteDirectoryEntry
import pl.dmq.peering.wire.RemoteEntryKind

/**
 * The folder on screen: what the browser holds, filtered by the search and the hidden-file choice, sorted, with the
 * selection, the open dialog and the progress of whatever the browser is sending or fetching.
 */
class FileListPresenter(
    private val port: FileBrowsingPort,
    private val scope: CoroutineScope,
) {
    private val view = MutableStateFlow(ListView())
    private val selection = FileSelection()

    val destination = DownloadDestination(port)

    private val shellReady: Flow<Boolean> = port.shell?.ready ?: flowOf(false)

    val ui: StateFlow<FileListUi> = combine(port.state, port.online, view, shellReady) { browser, online, current, shell ->
        derive(browser, online, current, shell)
    }.stateIn(scope, SharingStarted.Eagerly, derive(port.state.value, port.online.value, view.value, false))

    init {
        scope.launch {
            port.online.drop(1).filter { it }.collect { port.open(ui.value.path) }
        }
    }

    fun setSort(order: FileSort) = view.update { it.copy(sort = order) }

    fun toggleHidden() = view.update { it.copy(showsHidden = !it.showsHidden) }

    fun setQuery(query: String) = view.update { it.copy(query = query) }

    fun goTo(path: String) {
        clearSelection()
        port.list(path)
    }

    fun refresh() {
        port.list(ui.value.path)
    }

    /** One step toward the root, or false when the list is already at one. */
    fun up(): Boolean {
        if (!ui.value.canGoUp) return false
        clearSelection()
        port.up()
        return true
    }

    fun tap(row: FileRowUi) {
        if (ui.value.isSelecting) return toggleSelected(row)
        if (row.isFolder) view.update { it.copy(query = "") }
        port.openEntry(row.entry)
    }

    fun toggleSelected(row: FileRowUi) {
        selection.toggle(ui.value.path, row.name)
        view.update { it.copy(selectionVersion = it.selectionVersion + 1) }
    }

    fun selectAll() {
        selection.setAll(ui.value.path, ui.value.entries.map { it.name })
        view.update { it.copy(selectionVersion = it.selectionVersion + 1) }
    }

    fun clearSelection() {
        selection.clear()
        view.update { it.copy(selectionVersion = it.selectionVersion + 1) }
    }

    fun beginCreate(kind: RemoteEntryKind) {
        val folder = kind == RemoteEntryKind.FOLDER
        val suggestion = RemoteFileName.availableName(
            base = if (folder) NEW_FOLDER else NEW_FILE,
            extension = if (folder) "" else ".txt",
            existing = listedNames(),
        )
        val purpose = if (folder) FileDialog.Purpose.NEW_FOLDER else FileDialog.Purpose.NEW_FILE
        view.update { it.copy(dialog = FileDialog.Name(purpose, suggestion)) }
    }

    fun beginRename(entry: RemoteDirectoryEntry) {
        view.update { it.copy(dialog = FileDialog.Name(FileDialog.Purpose.RENAME, entry.name, entry)) }
    }

    fun beginDelete(entries: List<RemoteDirectoryEntry>) {
        if (entries.isNotEmpty()) view.update { it.copy(dialog = FileDialog.ConfirmDelete(entries)) }
    }

    fun beginDeleteSelected() = beginDelete(selectedEntries())

    /** Types the selected entry's path, quoted, on the command line of the shell in use; the person finishes the line. */
    fun putSelectedPathInShell() {
        val shell = port.shell ?: return
        val entry = selectedEntries().singleOrNull() ?: return
        val folder = ui.value.path ?: return
        shell.putPath(FilePath.child(folder, entry.name))
        clearSelection()
    }

    /** Asks before running the selected file, which runs with the person's permissions on the computer. */
    fun beginRunSelected() {
        val entry = selectedEntries().singleOrNull()?.takeIf { it.isExecutable && port.shell != null } ?: return
        view.update { it.copy(dialog = FileDialog.ConfirmRun(entry)) }
    }

    fun confirmRun() {
        val dialog = view.value.dialog as? FileDialog.ConfirmRun ?: return
        val folder = ui.value.path
        dismissDialog()
        if (folder != null) port.shell?.run(FilePath.child(folder, dialog.entry.name))
        clearSelection()
    }

    fun editName(text: String) {
        view.update { current ->
            val dialog = current.dialog as? FileDialog.Name ?: return@update current
            current.copy(dialog = dialog.copy(text = text, problem = null))
        }
    }

    fun confirmName() {
        val dialog = view.value.dialog as? FileDialog.Name ?: return
        val name = dialog.text
        val problem = nameProblem(name, dialog.target)
        if (problem != null) return view.update { it.copy(dialog = dialog.copy(problem = problem)) }
        if (dialog.purpose == FileDialog.Purpose.RENAME) {
            dialog.target?.let { port.rename(it, name) }
        } else {
            port.create(name, dialog.kind)
        }
        dismissDialog()
        clearSelection()
    }

    fun confirmDelete() {
        val dialog = view.value.dialog as? FileDialog.ConfirmDelete ?: return
        port.delete(dialog.entries)
        dismissDialog()
        clearSelection()
    }

    fun dismissDialog() = view.update { it.copy(dialog = null) }

    fun dismissFailures() = port.dismissFailures()

    /** Fetches [row], a folder as a zip, once the user has picked where it goes. */
    fun download(row: FileRowUi) {
        destination.ask(FilePath.child(ui.value.path ?: return, row.name), row.isFolder)
    }

    fun downloadSelected() {
        selectedEntries().singleOrNull()?.let { entry ->
            download(FileRowUi(entry, FileGlyph.of(entry), isSelected = true))
        }
    }

    fun cancelDownload() = port.cancelDownload()

    fun upload(sources: List<String>) {
        if (sources.isNotEmpty()) port.upload(sources)
    }

    fun cancelUpload() = port.cancelUpload()

    fun selectedEntries(): List<RemoteDirectoryEntry> = ui.value.entries.filter { it.isSelected }.map { it.entry }

    private fun listedNames(): List<String> = port.state.value.listing?.entries?.map { it.name }.orEmpty()

    private fun nameProblem(name: String, target: RemoteDirectoryEntry?): FileDialog.NameProblem? = when {
        !RemoteFileName.isValid(name) -> FileDialog.NameProblem.INVALID
        name != target?.name && listedNames().any { it.equals(name, ignoreCase = true) } -> FileDialog.NameProblem.TAKEN
        else -> null
    }

    private fun derive(browser: FileBrowserState, online: Boolean, current: ListView, shellReady: Boolean): FileListUi {
        val listing = browser.listing
        val matching = (listing?.entries ?: emptyList())
            .filter { current.showsHidden || !it.name.startsWith('.') }
        val needle = current.query.trim()
        val visible = matching.filter { needle.isEmpty() || it.name.contains(needle, ignoreCase = true) }
        val chosen = selection.namesFor(listing?.path)
        val rows = current.sort.sorted(visible).map { FileRowUi(it, FileGlyph.of(it), it.name in chosen) }
        val failure = browser.browseFailure
        val status = when {
            failure != null -> FileListStatus.ERROR
            listing == null && !online -> FileListStatus.OFFLINE
            listing == null -> FileListStatus.LOADING
            rows.isEmpty() && matching.isNotEmpty() && needle.isNotEmpty() -> FileListStatus.NO_MATCH
            rows.isEmpty() && !browser.listingLoading -> FileListStatus.EMPTY
            else -> FileListStatus.CONTENT
        }
        return FileListUi(
            status = status,
            path = listing?.path,
            breadcrumbs = listing?.path?.let { FilePath.breadcrumbs(it) } ?: emptyList(),
            entries = rows,
            failure = failure,
            failureKind = failure?.let(FileFailureKind::of) ?: FileFailureKind.OTHER,
            isTruncated = listing?.isTruncated == true,
            isRefreshing = browser.listingLoading && listing != null,
            canGoUp = listing?.parentPath != null,
            sort = current.sort,
            showsHidden = current.showsHidden,
            query = current.query,
            selectedCount = rows.count { it.isSelected },
            dialog = current.dialog,
            changeFailure = browser.changes.failure,
            isChanging = browser.changes.isRunning,
            isOffline = !online,
            upload = browser.upload,
            download = DownloadStatuses.of(browser.transfer, null) ?: DownloadStatus.Idle,
            canUseShell = shellReady,
        )
    }

    private data class ListView(
        val sort: FileSort = FileSort.NAME,
        val showsHidden: Boolean = false,
        val query: String = "",
        val dialog: FileDialog? = null,
        val selectionVersion: Int = 0,
    )

    private companion object {
        const val NEW_FOLDER = "New Folder"
        const val NEW_FILE = "New File"
    }
}
