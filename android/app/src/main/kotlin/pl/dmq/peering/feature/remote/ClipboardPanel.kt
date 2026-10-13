package pl.dmq.peering.feature.remote

import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import pl.dmq.peering.R
import pl.dmq.peering.session.clipboard.ClipboardContent
import pl.dmq.peering.session.clipboard.ClipboardEntry
import pl.dmq.peering.session.clipboard.ClipboardPush
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.wire.MAX_CLIPBOARD_IMAGE_BYTES

/** What the Clipboard panel asks of the session. */
class ClipboardActions(
    val ready: Boolean,
    val host: ClipboardContent?,
    val imagesAllowed: Boolean,
    val history: List<ClipboardEntry>,
    val onRequestHost: () -> Unit,
    val onSend: (String) -> Unit,
    val onPasteOnComputer: (String) -> Unit,
    val onSendImage: (png: ByteArray, paste: Boolean) -> ClipboardPush,
    val onRemoveEntry: (Long) -> Unit,
    val onClearHistory: () -> Unit,
)

private enum class Side { PHONE, COMPUTER }

/**
 * The Clipboard panel: the phone's row, with Send and Paste on computer, the computer's row, with Copy to phone, and
 * the History row that opens the list of what moved. Text and pictures move only when asked: the computer's clipboard
 * is read when the panel opens and again on request.
 */
@Composable
fun ClipboardPanel(actions: ClipboardActions, modifier: Modifier = Modifier) {
    var showingHistory by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { actions.onRequestHost() }
    if (showingHistory) {
        ClipboardHistoryList(actions, onBack = { showingHistory = false }, modifier)
    } else {
        ClipboardOverview(actions, onHistory = { showingHistory = true }, modifier)
    }
}

@Composable
private fun ClipboardOverview(actions: ClipboardActions, onHistory: () -> Unit, modifier: Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val manager = remember(context) { context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager }
    var phone by remember { mutableStateOf(manager.currentClip(context)) }
    var confirmed by remember { mutableStateOf<Side?>(null) }
    var feedback by remember { mutableStateOf<ClipboardFeedback>(ClipboardFeedback.Silent) }
    OnPrimaryClipChanged(manager) {
        phone = manager.currentClip(context)
        feedback = ClipboardFeedback.Silent
    }
    LaunchedEffect(confirmed) {
        if (confirmed != null) {
            delay(CONFIRM_MILLIS)
            confirmed = null
        }
    }
    Column(modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        PhoneClipboardRow(
            actions, phone, feedback,
            confirmed = confirmed == Side.PHONE,
            onFeedback = { feedback = it },
            onConfirmed = { confirmed = Side.PHONE },
        )
        ComputerClipboardRow(
            actions.host,
            confirmed = confirmed == Side.COMPUTER,
            onCopy = {
                scope.launch {
                    manager.copyContent(context, context.getString(R.string.clipboard_computer), actions.host)
                    confirmed = Side.COMPUTER
                }
            },
        )
        if (actions.history.isNotEmpty()) HistoryRow(actions.history.size, onHistory)
    }
}

@Composable
private fun OnPrimaryClipChanged(manager: ClipboardManager, onChanged: () -> Unit) {
    DisposableEffect(manager) {
        val listener = ClipboardManager.OnPrimaryClipChangedListener { onChanged() }
        manager.addPrimaryClipChangedListener(listener)
        onDispose { manager.removePrimaryClipChangedListener(listener) }
    }
}

@Composable
private fun PhoneClipboardRow(
    actions: ClipboardActions,
    phone: PhoneClip,
    feedback: ClipboardFeedback,
    confirmed: Boolean,
    onFeedback: (ClipboardFeedback) -> Unit,
    onConfirmed: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun sendPhoneImage(uri: Uri, paste: Boolean) {
        scope.launch {
            val result = when (val read = ClipboardImages.readPng(context, uri)) {
                is ImageRead.Png -> actions.onSendImage(read.bytes, paste).feedback()
                is ImageRead.TooLarge -> ClipboardFeedback.TooLarge(read.bytes)
                ImageRead.Unreadable -> ClipboardFeedback.Silent
            }
            onFeedback(result)
            if (result == ClipboardFeedback.Confirmed) onConfirmed()
        }
    }
    val text = (phone as? PhoneClip.Text)?.text
    val pictureUri = (phone as? PhoneClip.Image)?.uri
    val canSend = actions.ready && (text != null || (pictureUri != null && actions.imagesAllowed))
    fun send(paste: Boolean, sendText: (String) -> Unit) {
        if (pictureUri != null) {
            sendPhoneImage(pictureUri, paste)
        } else {
            sendText(text.orEmpty())
            onConfirmed()
        }
    }
    ClipboardRow(
        icon = SessionIcons.phone,
        title = stringResource(R.string.clipboard_phone),
        detail = phoneDetail(phone, feedback, actions.imagesAllowed),
        empty = phone == PhoneClip.Empty,
        confirmed = confirmed,
    ) {
        ClipAction(stringResource(R.string.clipboard_send), enabled = canSend) { send(paste = false, actions.onSend) }
        ClipAction(stringResource(R.string.clipboard_paste_on_computer), prominent = true, enabled = canSend) {
            send(paste = true, actions.onPasteOnComputer)
        }
    }
}

@Composable
private fun ComputerClipboardRow(host: ClipboardContent?, confirmed: Boolean, onCopy: () -> Unit) {
    val hasHostContent = host is ClipboardContent.Image || (host is ClipboardContent.Text && host.text.isNotEmpty())
    ClipboardRow(
        icon = AppIcons.computer,
        title = stringResource(R.string.clipboard_computer),
        detail = when {
            host == null -> stringResource(R.string.clipboard_not_checked)
            host is ClipboardContent.Image -> stringResource(R.string.clipboard_image)
            host is ClipboardContent.Text && hasHostContent -> host.text
            else -> stringResource(R.string.clipboard_nothing_to_copy)
        },
        empty = !hasHostContent,
        confirmed = confirmed,
    ) {
        ClipAction(stringResource(R.string.clipboard_copy_to_phone), enabled = hasHostContent, onClick = onCopy)
    }
}

@Composable
private fun phoneDetail(phone: PhoneClip, feedback: ClipboardFeedback, imagesAllowed: Boolean): String {
    val context = LocalContext.current
    return when {
        feedback is ClipboardFeedback.TooLarge -> stringResource(
            R.string.clipboard_image_too_large,
            Formatter.formatShortFileSize(context, feedback.bytes.toLong()),
            Formatter.formatShortFileSize(context, MAX_CLIPBOARD_IMAGE_BYTES.toLong()),
        )
        feedback is ClipboardFeedback.Unsupported -> stringResource(R.string.clipboard_image_unsupported)
        phone == PhoneClip.Empty -> stringResource(R.string.clipboard_nothing_copied)
        phone == PhoneClip.Other -> stringResource(R.string.clipboard_other_copied)
        phone is PhoneClip.Image -> stringResource(if (imagesAllowed) R.string.clipboard_image_copied else R.string.clipboard_image_unsupported)
        phone is PhoneClip.Text -> phone.text
        else -> stringResource(R.string.clipboard_nothing_copied)
    }
}

@Composable
private fun HistoryRow(count: Int, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().rowSurface().tappable(onClick).padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        ClipboardIconTile(SessionIcons.history)
        Text(stringResource(R.string.clipboard_history), style = PeeringText.subheadlineMedium, color = PeeringColors.ink)
        Text(count.toString(), style = PeeringText.caption, color = PeeringColors.muted)
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.End) {
            Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(18.dp))
        }
    }
}

private const val CONFIRM_MILLIS = 1_500L
