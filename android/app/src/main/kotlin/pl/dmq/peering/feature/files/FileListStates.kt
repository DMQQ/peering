package pl.dmq.peering.feature.files

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.TonalButton
import pl.dmq.peering.ui.theme.EmptyState

/** The folder shows nothing to list: say why, and offer the one thing that might change it. */
@Composable
fun FileListMessage(ui: FileListUi, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxSize().padding(horizontal = 32.dp), contentAlignment = Alignment.Center) {
        when (ui.status) {
            FileListStatus.LOADING -> Loading()
            FileListStatus.OFFLINE -> EmptyState(
                icon = AppIcons.wifiOff,
                title = stringResource(R.string.files_offline_title),
                body = stringResource(R.string.files_offline_body),
            )
            FileListStatus.ERROR -> EmptyState(
                icon = AppIcons.warning,
                title = stringResource(failureTitle(ui.failureKind)),
                body = ui.failure.orEmpty(),
                action = { TonalButton(onClick = onRetry) { Text(stringResource(R.string.files_retry)) } },
            )
            FileListStatus.NO_MATCH -> EmptyState(
                icon = AppIcons.folder,
                title = stringResource(R.string.files_no_match, ui.query.trim()),
                body = "",
            )
            FileListStatus.EMPTY -> EmptyState(
                icon = AppIcons.folder,
                title = stringResource(R.string.files_folder_empty),
                body = "",
            )
            FileListStatus.CONTENT -> Unit
        }
    }
}

/** A slow first listing usually means the computer is asking its owner a question, so after a moment it says so. */
@Composable
private fun Loading() {
    var slow by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        delay(SLOW_LISTING_MILLIS)
        slow = true
    }
    Column(verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        if (slow) {
            EmptyState(
                icon = AppIcons.computer,
                title = stringResource(R.string.files_waiting_title),
                body = stringResource(R.string.files_waiting_body),
            )
        }
        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
    }
}

private fun failureTitle(kind: FileFailureKind): Int = when (kind) {
    FileFailureKind.PERMISSION_DENIED -> R.string.files_error_permission_title
    FileFailureKind.NOT_FOUND -> R.string.files_error_missing_title
    FileFailureKind.OTHER -> R.string.files_error_other_title
}

private const val SLOW_LISTING_MILLIS = 2500L
