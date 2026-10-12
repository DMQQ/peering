package pl.dmq.peering.feature.files

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier

/** The files of one Mac: its folders, and the file open in the preview over them. */
@Composable
fun FilesRoute(port: FileBrowsingPort, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val list = remember(port) { FileListPresenter(port, scope) }
    val preview = remember(port) { FilePreviewPresenter(port, scope) }
    val previewState by preview.ui.collectAsState()

    LaunchedEffect(port) {
        if (port.state.value.listing == null) port.open(null)
    }

    Surface(modifier = modifier, color = MaterialTheme.colorScheme.background) {
        if (previewState != null) {
            FilePreviewScreen(presenter = preview)
        } else {
            FileList(presenter = list)
        }
    }
}
