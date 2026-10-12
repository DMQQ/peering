package pl.dmq.peering.feature.files

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import pl.dmq.peering.session.files.FilePath
import pl.dmq.peering.session.files.FileUpload
import pl.dmq.peering.session.files.UploadFailure
import pl.dmq.peering.ui.theme.PeeringColors

/** What is going on beside the list: a refused change, a lost link, and the upload and download in flight. */
@Composable
fun FileBanners(ui: FileListUi, presenter: FileListPresenter, modifier: Modifier = Modifier) {
    Column(modifier = modifier.fillMaxWidth()) {
        if (ui.isOffline && ui.path != null) {
            Banner(stringResource(R.string.files_offline_banner), PeeringColors.caution)
        }
        ui.changeFailure?.let { Banner(it, PeeringColors.caution, onDismiss = presenter::dismissFailures) }
        UploadBanner(ui.upload, presenter)
        DownloadBanner(ui.download, presenter)
    }
}

@Composable
private fun UploadBanner(upload: FileUpload, presenter: FileListPresenter) {
    when (upload) {
        FileUpload.Idle -> Unit
        is FileUpload.Running -> Progress(
            label = stringResource(R.string.files_uploading, FilePath.name(upload.path), (upload.fraction * PERCENT).toInt()),
            fraction = upload.fraction.toFloat(),
            onCancel = presenter::cancelUpload,
        )
        is FileUpload.Done -> Banner(stringResource(R.string.files_upload_done), PeeringColors.added, onDismiss = presenter::dismissFailures)
        is FileUpload.Failed -> Banner(
            text = when (val reason = upload.reason) {
                UploadFailure.TooLarge -> stringResource(R.string.files_upload_too_large)
                UploadFailure.Unreadable -> stringResource(R.string.files_upload_unreadable)
                UploadFailure.InvalidName -> stringResource(R.string.files_upload_invalid_name)
                is UploadFailure.Host -> reason.message
            },
            tint = PeeringColors.danger,
            onDismiss = presenter::dismissFailures,
        )
    }
}

@Composable
private fun DownloadBanner(download: DownloadStatus, presenter: FileListPresenter) {
    when (download) {
        DownloadStatus.Idle -> Unit
        is DownloadStatus.Running -> Progress(
            label = if (download.isZipping) {
                stringResource(R.string.preview_preparing_folder)
            } else {
                stringResource(R.string.files_downloading, ((download.fraction ?: 0.0) * PERCENT).toInt())
            },
            fraction = if (download.isZipping) null else (download.fraction ?: 0.0).toFloat(),
            onCancel = presenter::cancelDownload,
        )
        DownloadStatus.Finished -> Banner(stringResource(R.string.preview_saved), PeeringColors.added, onDismiss = presenter::cancelDownload)
        is DownloadStatus.Failed -> Banner(
            text = when (val problem = download.problem) {
                DownloadProblem.TooLarge -> stringResource(R.string.preview_too_large)
                DownloadProblem.ShortRead -> stringResource(R.string.preview_short_read)
                DownloadProblem.Destination -> stringResource(R.string.preview_destination_failed)
                is DownloadProblem.Transfer -> problem.message.ifBlank { stringResource(R.string.preview_download_failed) }
            },
            tint = PeeringColors.danger,
            onDismiss = presenter::cancelDownload,
        )
    }
}

@Composable
private fun Banner(text: String, tint: Color, onDismiss: (() -> Unit)? = null) {
    Row(
        modifier = Modifier.fillMaxWidth().background(tint.copy(alpha = 0.12f)).padding(start = 16.dp).heightIn(min = 48.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(text, style = MaterialTheme.typography.bodyMedium, color = tint, modifier = Modifier.weight(1f).padding(vertical = 8.dp))
        if (onDismiss != null) {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.files_dismiss), color = tint) }
        }
    }
}

@Composable
private fun Progress(label: String, fraction: Float?, onCancel: () -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().background(PeeringColors.containerHigh)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp).heightIn(min = 48.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, style = MaterialTheme.typography.bodyMedium, color = PeeringColors.ink, maxLines = 1, modifier = Modifier.weight(1f))
            TextButton(onClick = onCancel) { Text(stringResource(R.string.files_cancel), color = PeeringColors.accent) }
        }
        if (fraction == null) {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        } else {
            LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
        }
    }
}

private const val PERCENT = 100
