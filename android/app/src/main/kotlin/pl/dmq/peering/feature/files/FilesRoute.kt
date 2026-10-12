package pl.dmq.peering.feature.files

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors

/** The files of one Mac under a top app bar: its folders, and the file open in the preview over them. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FilesRoute(port: FileBrowsingPort, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val list = remember(port) { FileListPresenter(port, scope) }
    val preview = remember(port) { FilePreviewPresenter(port, scope) }
    val previewState by preview.ui.collectAsState()
    val destinationRequest by preview.destinationRequest.collectAsState()
    val pickDestination = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(OCTET_STREAM)) {
        preview.destinationChosen(it?.toString())
    }

    LaunchedEffect(port) {
        if (port.state.value.listing == null) port.open(null)
    }

    LaunchedEffect(destinationRequest) {
        destinationRequest?.let { pickDestination.launch(FilePath.name(it)) }
    }

    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(previewState?.path?.let(FilePath::name) ?: stringResource(R.string.hub_files), maxLines = 1) },
                navigationIcon = {
                    val inPreview = previewState != null
                    IconButton(onClick = if (inPreview) preview::close else onBack) {
                        Icon(
                            imageVector = if (inPreview) AppIcons.close else AppIcons.back,
                            contentDescription = stringResource(if (inPreview) R.string.preview_close else R.string.files_back),
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent, titleContentColor = PeeringColors.ink),
            )
        },
    ) { padding ->
        if (previewState != null) {
            FilePreviewScreen(presenter = preview, modifier = Modifier.padding(padding))
        } else {
            FileList(presenter = list, modifier = Modifier.padding(padding))
        }
    }
}

private const val OCTET_STREAM = "application/octet-stream"
