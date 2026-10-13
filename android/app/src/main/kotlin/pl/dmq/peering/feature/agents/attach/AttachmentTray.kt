package pl.dmq.peering.feature.agents.attach

import android.content.Context
import android.net.Uri
import android.util.Size
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.AttachmentChipUi
import pl.dmq.peering.session.files.TransferLimits
import pl.dmq.peering.session.files.UploadFailure
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

private const val THUMBNAIL_PIXELS = 160

/** The files waiting to go with the next message, a failed one in the danger colour, and the one on its way dimmed with a spinner. */
@Composable
fun AttachmentTray(
    chips: List<AttachmentChipUi>,
    uploadingName: String?,
    onRemoveAttached: (index: Int) -> Unit,
    onRemoveFailed: (key: Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (chips.isEmpty() && uploadingName == null) return
    Row(
        modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 14.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        chips.forEachIndexed { index, chip ->
            FileChip(
                name = chip.name,
                thumbnailUri = chip.thumbnailUri,
                failure = chip.failure,
                uploading = false,
                onRemove = { chip.failedKey?.let(onRemoveFailed) ?: onRemoveAttached(index) },
            )
        }
        if (uploadingName != null) FileChip(uploadingName, thumbnailUri = null, failure = null, uploading = true, onRemove = null)
    }
}

@Composable
private fun FileChip(name: String, thumbnailUri: String?, failure: UploadFailure?, uploading: Boolean, onRemove: (() -> Unit)?) {
    val shape = peeringShapes.small
    val edge = if (failure == null) PeeringColors.ink.copy(alpha = 0.16f) else PeeringColors.danger.copy(alpha = 0.4f)
    Row(
        Modifier.clip(shape).border(1.dp, edge, shape).padding(5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        ChipTile(thumbnailUri, failed = failure != null, uploading = uploading)
        Column(Modifier.widthIn(max = 150.dp)) {
            Text(
                name,
                style = PeeringText.caption.copy(fontSize = 12.5.sp),
                color = if (failure == null) PeeringColors.ink else PeeringColors.danger,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            when {
                failure != null -> Text(failureText(failure), style = PeeringText.caption2, color = PeeringColors.danger.copy(alpha = 0.8f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                uploading -> Text(stringResource(R.string.agents_attach_sending), style = PeeringText.caption2, color = PeeringColors.ink.copy(alpha = 0.5f), maxLines = 1)
            }
        }
        if (onRemove != null) {
            IconButton(onClick = onRemove, modifier = Modifier.size(32.dp)) {
                Icon(AppIcons.close, contentDescription = stringResource(R.string.agents_attach_remove), tint = PeeringColors.ink.copy(alpha = 0.7f), modifier = Modifier.size(14.dp))
            }
        }
    }
}

@Composable
private fun ChipTile(thumbnailUri: String?, failed: Boolean, uploading: Boolean) {
    val context = LocalContext.current
    val thumbnail by produceState<ImageBitmap?>(null, thumbnailUri) {
        value = thumbnailUri?.let { withContext(Dispatchers.IO) { loadThumbnail(context, it) } }
    }
    Box(
        Modifier.size(36.dp).clip(peeringShapes.extraSmall).background(PeeringColors.ink.copy(alpha = 0.1f)),
        contentAlignment = Alignment.Center,
    ) {
        val image = thumbnail
        if (image != null) {
            Image(image, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.size(36.dp))
        } else {
            Icon(
                if (failed) AppIcons.warning else AppIcons.file,
                contentDescription = null,
                tint = if (failed) PeeringColors.danger else PeeringColors.ink.copy(alpha = 0.85f),
                modifier = Modifier.size(18.dp),
            )
        }
        if (uploading) {
            Box(Modifier.size(36.dp).background(PeeringColors.backdrop.copy(alpha = 0.35f)), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = PeeringColors.ink, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            }
        }
    }
}

/** A small preview the system draws from the picked picture; null where it cannot, and the tile shows a file glyph instead. */
private fun loadThumbnail(context: Context, uri: String): ImageBitmap? = runCatching {
    context.contentResolver.loadThumbnail(Uri.parse(uri), Size(THUMBNAIL_PIXELS, THUMBNAIL_PIXELS), null).asImageBitmap()
}.getOrNull()

@Composable
private fun failureText(failure: UploadFailure): String = when (failure) {
    UploadFailure.TooLarge -> stringResource(R.string.agents_attach_too_large, TransferLimits.MAXIMUM_PHONE_UPLOAD_BYTES / BYTES_PER_MEGABYTE)
    UploadFailure.Unreadable -> stringResource(R.string.agents_attach_unreadable)
    UploadFailure.InvalidName -> stringResource(R.string.agents_attach_bad_name)
    is UploadFailure.Host -> failure.message
}

private const val BYTES_PER_MEGABYTE = 1024 * 1024
