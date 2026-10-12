package pl.dmq.peering.feature.files

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.wire.RemoteFileKind

/** One file opened for viewing, with the progress of its download under it. */
@Composable
fun FilePreviewScreen(presenter: FilePreviewPresenter, modifier: Modifier = Modifier) {
    val ui by presenter.ui.collectAsState()
    val current = ui ?: return
    Column(modifier = modifier.fillMaxSize()) {
        PreviewBody(current, modifier = Modifier.weight(1f))
        PreviewDownload(current.download, presenter)
    }
}

@Composable
private fun PreviewBody(ui: FilePreviewUi, modifier: Modifier) {
    when (val content = ui.content) {
        is PreviewContent.Loading -> Column(modifier = modifier.padding(16.dp), verticalArrangement = Arrangement.Center) {
            content.fraction?.let { fraction ->
                LinearProgressIndicator(progress = { fraction.toFloat() }, modifier = Modifier.fillMaxWidth())
            } ?: LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
        is PreviewContent.Text -> TextPreviewView(content, ui.wraps, modifier)
        is PreviewContent.Markdown -> MarkdownPreviewView(content, modifier)
        is PreviewContent.Image -> PictureContent(content.bytes, modifier)
        PreviewContent.Empty -> Notice(stringResource(R.string.preview_empty), PeeringColors.muted, modifier)
        is PreviewContent.TooLarge -> Notice(
            stringResource(R.string.preview_picture_too_large, fileSizeLabel(content.totalBytes)),
            PeeringColors.muted,
            modifier,
        )
        is PreviewContent.Unsupported -> Notice(
            stringResource(
                if (content.kind == RemoteFileKind.TEXT) R.string.preview_unsupported_text else R.string.preview_unsupported_kind,
            ),
            PeeringColors.muted,
            modifier,
        )
        is PreviewContent.Failed -> Notice(content.message, PeeringColors.danger, modifier)
    }
}

@Composable
private fun Notice(text: String, tint: Color, modifier: Modifier) {
    Box(modifier = modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Text(text, style = MaterialTheme.typography.bodyMedium, color = tint, textAlign = TextAlign.Center)
    }
}

@Composable
private fun PictureContent(bytes: ByteArray, modifier: Modifier) {
    val bitmap = remember(bytes) { ImageBitmapDecoder.decode(bytes) }
    if (bitmap == null) {
        Notice(stringResource(R.string.preview_unsupported_kind), PeeringColors.muted, modifier)
    } else {
        Image(
            bitmap = bitmap,
            contentDescription = null,
            modifier = modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
        )
    }
}
