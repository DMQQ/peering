package pl.dmq.peering.feature.remote

import android.content.ClipboardManager
import android.content.Context
import android.text.format.DateUtils
import androidx.compose.foundation.Image
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import pl.dmq.peering.R
import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.clipboard.ClipboardEntry
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringAlert
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

/**
 * What moved, newest first. Tapping a row copies it to the phone, a long press offers sending it to the computer or
 * deleting it. Clear asks first, since the list is the only copy.
 */
@Composable
internal fun ClipboardHistoryList(actions: ClipboardActions, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val manager = remember(context) { context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager }
    var justCopied by remember { mutableStateOf<Long?>(null) }
    var confirmsClear by remember { mutableStateOf(false) }
    Column(modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        HistoryHeader(onBack, hasEntries = actions.history.isNotEmpty(), onClear = { confirmsClear = true })
        if (actions.history.isEmpty()) HistoryEmptyNote()
        LazyColumn(Modifier.heightIn(max = LIST_MAX_HEIGHT), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(actions.history, key = { it.id }) { entry ->
                HistoryEntryRow(
                    entry = entry,
                    copied = justCopied == entry.id,
                    canSend = actions.ready && (entry.content !is ClipboardContent.Image || actions.imagesAllowed),
                    onCopy = {
                        scope.launch {
                            manager.copyContent(context, context.getString(R.string.clipboard_history), entry.content)
                            justCopied = entry.id
                        }
                    },
                    onSend = { actions.sendEntry(entry.content) },
                    onDelete = { actions.onRemoveEntry(entry.id) },
                )
            }
        }
    }
    if (confirmsClear) {
        ClearHistoryAlert(
            onConfirm = {
                confirmsClear = false
                actions.onClearHistory()
            },
            onCancel = { confirmsClear = false },
        )
    }
}

private fun ClipboardActions.sendEntry(content: ClipboardContent) {
    when (content) {
        is ClipboardContent.Text -> onSend(content.text)
        is ClipboardContent.Image -> onSendImage(content.png, false)
    }
}

@Composable
private fun HistoryHeader(onBack: () -> Unit, hasEntries: Boolean, onClear: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.tappable(onBack).padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Icon(AppIcons.back, contentDescription = stringResource(R.string.clipboard_back), tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
            Text(stringResource(R.string.clipboard_history), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
        }
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.End) {
            if (hasEntries) {
                Text(
                    stringResource(R.string.clipboard_clear),
                    style = PeeringText.subheadlineMedium,
                    color = PeeringColors.danger,
                    modifier = Modifier.tappable(onClear).padding(horizontal = 8.dp, vertical = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun HistoryEmptyNote() {
    Text(
        stringResource(R.string.clipboard_history_empty),
        style = PeeringText.caption,
        color = PeeringColors.muted,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
    )
}

@Composable
private fun ClearHistoryAlert(onConfirm: () -> Unit, onCancel: () -> Unit) {
    PeeringAlert(
        title = stringResource(R.string.clipboard_clear_title),
        message = stringResource(R.string.clipboard_clear_message),
        confirm = stringResource(R.string.clipboard_clear),
        onConfirm = onConfirm,
        cancel = stringResource(R.string.clipboard_cancel),
        onCancel = onCancel,
        destructive = true,
    )
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun HistoryEntryRow(
    entry: ClipboardEntry,
    copied: Boolean,
    canSend: Boolean,
    onCopy: () -> Unit,
    onSend: () -> Unit,
    onDelete: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Box {
        Column(
            Modifier
                .fillMaxWidth()
                .rowSurface()
                .combinedClickable(onClick = onCopy, onLongClick = { menuOpen = true })
                .padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            HistoryEntryContent(entry, copied)
        }
        PeeringMenu(expanded = menuOpen, onDismiss = { menuOpen = false }) {
            PeeringMenuItem(
                title = stringResource(R.string.clipboard_send_to_computer),
                icon = AppIcons.computer,
                enabled = canSend,
                onClick = {
                    menuOpen = false
                    onSend()
                },
            )
            PeeringMenuItem(
                title = stringResource(R.string.clipboard_delete),
                icon = AppIcons.delete,
                destructive = true,
                onClick = {
                    menuOpen = false
                    onDelete()
                },
            )
        }
    }
}

@Composable
private fun HistoryEntryContent(entry: ClipboardEntry, copied: Boolean) {
    when (val content = entry.content) {
        is ClipboardContent.Text -> Text(content.text, style = PeeringText.subheadline, color = PeeringColors.ink, maxLines = 3, overflow = TextOverflow.Ellipsis)
        is ClipboardContent.Image -> HistoryThumbnail(entry.id, content)
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(relativeTime(entry.atMillis), style = PeeringText.caption2, color = PeeringColors.tertiary)
        if (copied) {
            Icon(AppIcons.check, contentDescription = null, tint = PeeringColors.accent, modifier = Modifier.size(12.dp))
            Text(stringResource(R.string.clipboard_copied), style = PeeringText.caption2, color = PeeringColors.accent)
        }
    }
}

@Composable
private fun HistoryThumbnail(id: Long, image: ClipboardContent.Image) {
    val bitmap by produceState<androidx.compose.ui.graphics.ImageBitmap?>(null, id) {
        value = ClipboardImages.thumbnail(image.png, THUMBNAIL_EDGE)?.asImageBitmap()
    }
    val shown = bitmap
    if (shown != null) {
        Image(
            bitmap = shown,
            contentDescription = stringResource(R.string.clipboard_image),
            contentScale = ContentScale.Fit,
            alignment = Alignment.CenterStart,
            modifier = Modifier.heightIn(max = 96.dp).clip(peeringShapes.extraSmall),
        )
    } else {
        Text(stringResource(R.string.clipboard_image), style = PeeringText.subheadline, color = PeeringColors.muted)
    }
}

private fun relativeTime(atMillis: Long): String =
    DateUtils.getRelativeTimeSpanString(atMillis, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()

private val LIST_MAX_HEIGHT = 340.dp
private const val THUMBNAIL_EDGE = 320
