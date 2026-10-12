package pl.dmq.peering.feature.files

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

/** What the file's download is doing, under the preview. Idle shows nothing: the app bar starts one. */
@Composable
fun PreviewDownload(status: DownloadStatus, presenter: FilePreviewPresenter) {
    when (status) {
        DownloadStatus.Idle -> Unit
        is DownloadStatus.Running -> {
            Row(
                modifier = Modifier.fillMaxWidth().padding(start = 16.dp).heightIn(min = 48.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    if (status.isZipping) {
                        stringResource(R.string.preview_preparing_folder)
                    } else {
                        stringResource(R.string.preview_downloading, ((status.fraction ?: 0.0) * 100).toInt())
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = PeeringColors.muted,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = presenter::cancelDownload) {
                    Text(stringResource(R.string.preview_cancel), color = PeeringColors.ink)
                }
            }
            LinearProgressIndicator(progress = { (status.fraction ?: 0.0).toFloat() }, modifier = Modifier.fillMaxWidth())
        }
        DownloadStatus.Finished -> Message(stringResource(R.string.preview_saved), PeeringColors.added)
        is DownloadStatus.Failed -> Message(
            when (val problem = status.problem) {
                DownloadProblem.TooLarge -> stringResource(R.string.preview_too_large)
                DownloadProblem.ShortRead -> stringResource(R.string.preview_short_read)
                DownloadProblem.Destination -> stringResource(R.string.preview_destination_failed)
                is DownloadProblem.Transfer -> problem.message.ifBlank { stringResource(R.string.preview_download_failed) }
            },
            PeeringColors.danger,
        )
    }
}

@Composable
private fun Message(text: String, tint: Color) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = tint, modifier = Modifier.padding(16.dp))
}
