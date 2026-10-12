package pl.dmq.peering.feature.files

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.wire.RemoteFileKind
import pl.dmq.peering.ui.theme.PeeringColors

/** One file opened for viewing, with its download beside it. */
@Composable
fun FilePreviewScreen(presenter: FilePreviewPresenter, modifier: Modifier = Modifier) {
    val ui by presenter.ui.collectAsState()
    val current = ui ?: return
    Column(
        modifier = modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                FilePath.name(current.path),
                style = MaterialTheme.typography.titleMedium,
                color = PeeringColors.ink,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            Text(
                stringResource(R.string.preview_close),
                style = MaterialTheme.typography.labelLarge,
                color = PeeringColors.muted,
                modifier = Modifier.clickable(onClick = presenter::close),
            )
        }
        PreviewBody(current.content, modifier = Modifier.weight(1f))
        DownloadRow(current.download, presenter)
    }
}

@Composable
private fun PreviewBody(content: PreviewContent, modifier: Modifier) {
    when (content) {
        is PreviewContent.Loading -> Column(modifier = modifier, verticalArrangement = Arrangement.Center) {
            content.fraction?.let { fraction ->
                LinearProgressIndicator(progress = { fraction.toFloat() }, modifier = Modifier.fillMaxWidth())
            } ?: LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
        is PreviewContent.Text -> Column(modifier = modifier) {
            if (content.isTruncated) {
                Text(
                    stringResource(R.string.preview_truncated, fileSizeLabel(content.shownBytes), fileSizeLabel(content.totalBytes)),
                    style = MaterialTheme.typography.bodySmall,
                    color = PeeringColors.caution,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
            }
            LazyColumn {
                items(content.lines) { line ->
                    Text(
                        line,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        color = PeeringColors.ink,
                    )
                }
            }
        }
        is PreviewContent.Image -> PictureContent(content.bytes, modifier)
        is PreviewContent.Unsupported -> Text(
            stringResource(
                if (content.kind == RemoteFileKind.TEXT) R.string.preview_unsupported_text else R.string.preview_unsupported_kind,
            ),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
            modifier = modifier,
        )
        is PreviewContent.Failed -> Text(
            content.message,
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.danger,
            modifier = modifier,
        )
    }
}

@Composable
private fun PictureContent(bytes: ByteArray, modifier: Modifier) {
    val bitmap = remember(bytes) { ImageBitmapDecoder.decode(bytes) }
    if (bitmap == null) {
        Text(
            stringResource(R.string.preview_unsupported_kind),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
            modifier = modifier,
        )
    } else {
        Image(
            bitmap = bitmap,
            contentDescription = null,
            modifier = modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
        )
    }
}

@Composable
private fun DownloadRow(status: DownloadStatus, presenter: FilePreviewPresenter) {
    when (status) {
        DownloadStatus.Idle -> Button(
            onClick = presenter::download,
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = PeeringColors.ink, contentColor = PeeringColors.onInk),
        ) {
            Text(stringResource(R.string.preview_download), style = MaterialTheme.typography.labelLarge)
        }
        is DownloadStatus.Running -> Row(
            modifier = Modifier.fillMaxWidth(),
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
            Text(
                stringResource(R.string.preview_cancel),
                style = MaterialTheme.typography.labelLarge,
                color = PeeringColors.ink,
                modifier = Modifier.clickable(onClick = presenter::cancelDownload),
            )
        }
        DownloadStatus.Finished -> Text(stringResource(R.string.preview_saved), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.added)
        is DownloadStatus.Failed -> Text(
            when (val problem = status.problem) {
                DownloadProblem.TooLarge -> stringResource(R.string.preview_too_large)
                DownloadProblem.ShortRead -> stringResource(R.string.preview_short_read)
                is DownloadProblem.Transfer -> problem.message.ifBlank { stringResource(R.string.preview_download_failed) }
            },
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.danger,
        )
    }
}
