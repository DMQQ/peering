package pl.dmq.peering.feature.files

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

private sealed interface PdfState {
    data object Opening : PdfState

    data object Unreadable : PdfState

    class Open(val document: PdfDocument) : PdfState
}

/** A PDF drawn page by page in a scrolling column, only the pages on screen. */
@Composable
internal fun PdfPreviewView(bytes: ByteArray, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val state by produceState<PdfState>(PdfState.Opening, bytes) {
        value = PdfDocument.open(context.cacheDir.resolve(PDF_DIRECTORY), bytes)?.let { PdfState.Open(it) } ?: PdfState.Unreadable
    }
    val open = state as? PdfState.Open
    DisposableEffect(open) {
        onDispose { open?.let { scope.launch { it.document.close() } } }
    }
    when (val current = state) {
        PdfState.Opening -> LinearProgressIndicator(modifier = modifier.fillMaxWidth())
        PdfState.Unreadable -> PreviewNotice(stringResource(R.string.preview_pdf_unreadable), PeeringColors.muted, modifier)
        is PdfState.Open -> PdfPages(current.document, modifier)
    }
}

@Composable
private fun PdfPages(document: PdfDocument, modifier: Modifier) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        val widthPx = with(LocalDensity.current) { maxWidth.roundToPx() }
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items((0 until document.pageCount).toList(), key = { it }) { index -> PdfPage(document, index, widthPx) }
        }
    }
}

@Composable
private fun PdfPage(document: PdfDocument, index: Int, widthPx: Int) {
    val bitmap by produceState<ImageBitmap?>(null, document, index, widthPx) {
        value = document.render(index, widthPx).asImageBitmap()
    }
    val drawn = bitmap
    if (drawn != null) {
        Image(bitmap = drawn, contentDescription = stringResource(R.string.preview_pdf_page, index + 1), contentScale = ContentScale.FillWidth, modifier = Modifier.fillMaxWidth())
    } else {
        Box(Modifier.fillMaxWidth().aspectRatio(PLACEHOLDER_ASPECT))
    }
}

private const val PDF_DIRECTORY = "pdf-preview"
private const val PLACEHOLDER_ASPECT = 0.77f
