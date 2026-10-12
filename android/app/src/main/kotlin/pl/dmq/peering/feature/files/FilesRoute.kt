package pl.dmq.peering.feature.files

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.feature.remote.HubTab
import pl.dmq.peering.feature.remote.ReportHubPage
import pl.dmq.peering.feature.remote.belowHubSwitcher
import pl.dmq.peering.session.files.FilePath

/**
 * The files of one computer: its folders under a path bar, and the file open in the preview over them. A [hosted] page
 * sits under a switcher that closes it, so the folder bar has no back arrow of its own; a preview keeps its own.
 */
@Composable
fun FilesRoute(port: FileBrowsingPort, onBack: () -> Unit, modifier: Modifier = Modifier, hosted: Boolean = false) {
    val scope = rememberCoroutineScope()
    val list = remember(port) { FileListPresenter(port, scope) }
    val preview = remember(port) { FilePreviewPresenter(port, scope) }
    val listUi by list.ui.collectAsState()
    val previewUi by preview.ui.collectAsState()
    var searching by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(port) {
        if (port.state.value.listing == null) port.open(null)
    }
    FileLaunchers(list, preview)
    ReportHubPage(HubTab.FILES, atRoot = previewUi == null && !searching)

    fun closeSearch() {
        list.setQuery("")
        searching = false
    }

    fun goBack() {
        when {
            previewUi != null -> preview.close()
            listUi.isSelecting -> list.clearSelection()
            searching -> closeSearch()
            !list.up() -> onBack()
        }
    }
    BackHandler(onBack = ::goBack)

    val pickDocuments = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        list.upload(uris.map { it.toString() })
    }

    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            val open = previewUi
            when {
                open != null -> PreviewTopBar(open, preview)
                listUi.isSelecting -> Box(Modifier.belowHubSwitcher()) { SelectionTopBar(listUi, list) }
                searching -> SearchTopBar(listUi.query, list::setQuery, ::closeSearch)
                else -> Box(Modifier.belowHubSwitcher()) {
                    FolderTopBar(listUi, list, onBack = if (hosted) null else ::goBack, onSearch = { searching = true })
                }
            }
        },
        floatingActionButton = {
            if (previewUi == null && !listUi.isSelecting && !searching && listUi.path != null) {
                NewEntryButton(enabled = listUi.canChange, presenter = list, onUpload = { pickDocuments.launch(arrayOf("*/*")) })
            }
        },
    ) { padding ->
        val open = previewUi
        if (open != null) {
            FilePreviewScreen(presenter = preview, modifier = Modifier.padding(padding))
        } else {
            Column(modifier = Modifier.padding(padding)) {
                if (listUi.breadcrumbs.isNotEmpty()) BreadcrumbBar(listUi.breadcrumbs, onGoTo = list::goTo)
                FileBanners(listUi, list)
                FileList(listUi, list, modifier = Modifier.weight(1f))
            }
        }
    }
    FileDialogHost(listUi.dialog, list)
}

/** The system pickers a download or a share needs, and what to do with what they return. */
@Composable
private fun FileLaunchers(list: FileListPresenter, preview: FilePreviewPresenter) {
    val context = LocalContext.current
    val chooserTitle = stringResource(R.string.preview_share)
    val listDestination by list.destination.request.collectAsState()
    val previewDestination by preview.destinationRequest.collectAsState()
    val share by preview.shareRequest.collectAsState()
    val saveListed = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(OCTET_STREAM)) {
        list.destination.chosen(it?.toString())
    }
    val savePreviewed = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(OCTET_STREAM)) {
        preview.destinationChosen(it?.toString())
    }
    LaunchedEffect(listDestination) { listDestination?.let { saveListed.launch(it.suggestedName) } }
    LaunchedEffect(previewDestination) { previewDestination?.let { savePreviewed.launch(FilePath.name(it)) } }
    LaunchedEffect(share) {
        share?.let {
            FileShare.share(context, it, chooserTitle)
            preview.shareHandled()
        }
    }
}

private const val OCTET_STREAM = "application/octet-stream"
