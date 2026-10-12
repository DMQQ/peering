package pl.dmq.peering.feature.files

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import pl.dmq.peering.session.files.FilePath

/** The files of one Mac: its folders, and the file open in the preview over them. */
@Composable
fun FilesRoute(port: FileBrowsingPort, modifier: Modifier = Modifier) {
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

    Surface(modifier = modifier, color = MaterialTheme.colorScheme.background) {
        if (previewState != null) {
            FilePreviewScreen(presenter = preview)
        } else {
            FileList(presenter = list)
        }
    }
}

private const val OCTET_STREAM = "application/octet-stream"
