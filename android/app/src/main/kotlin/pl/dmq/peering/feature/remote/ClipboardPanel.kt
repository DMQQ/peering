package pl.dmq.peering.feature.remote

import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.rowSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

/** What the Clipboard panel asks of the session. */
class ClipboardActions(
    val ready: Boolean,
    val hostText: String?,
    val onRequestHost: () -> Unit,
    val onSend: (String) -> Unit,
    val onPasteOnComputer: (String) -> Unit,
)

private enum class Side { PHONE, COMPUTER }

/**
 * The Clipboard panel: the phone's row, with Send and Paste on computer, and the computer's row, with Copy to phone.
 * Text moves only when asked: the computer's clipboard is read when the panel opens and again on request.
 */
@Composable
fun ClipboardPanel(actions: ClipboardActions, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val manager = remember(context) { context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager }
    var phone by remember { mutableStateOf(manager.currentClip(context)) }
    var confirmed by remember { mutableStateOf<Side?>(null) }
    DisposableEffect(manager) {
        val listener = ClipboardManager.OnPrimaryClipChangedListener { phone = manager.currentClip(context) }
        manager.addPrimaryClipChangedListener(listener)
        onDispose { manager.removePrimaryClipChangedListener(listener) }
    }
    LaunchedEffect(Unit) { actions.onRequestHost() }
    LaunchedEffect(confirmed) {
        if (confirmed != null) {
            delay(CONFIRM_MILLIS)
            confirmed = null
        }
    }
    val text = (phone as? PhoneClip.Text)?.text
    Column(modifier.fillMaxWidth().padding(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ClipboardRow(
            icon = SessionIcons.phone,
            title = stringResource(R.string.clipboard_phone),
            detail = when (phone) {
                PhoneClip.Empty -> stringResource(R.string.clipboard_nothing_copied)
                PhoneClip.Other -> stringResource(R.string.clipboard_other_copied)
                is PhoneClip.Text -> text.orEmpty()
            },
            empty = phone == PhoneClip.Empty,
            confirmed = confirmed == Side.PHONE,
        ) {
            ClipAction(stringResource(R.string.clipboard_send), enabled = text != null && actions.ready) {
                actions.onSend(text.orEmpty())
                confirmed = Side.PHONE
            }
            ClipAction(stringResource(R.string.clipboard_paste_on_computer), prominent = true, enabled = text != null && actions.ready) {
                actions.onPasteOnComputer(text.orEmpty())
                confirmed = Side.PHONE
            }
        }
        val host = actions.hostText
        ClipboardRow(
            icon = AppIcons.computer,
            title = stringResource(R.string.clipboard_computer),
            detail = when {
                host == null -> stringResource(R.string.clipboard_not_checked)
                host.isEmpty() -> stringResource(R.string.clipboard_nothing_to_copy)
                else -> host
            },
            empty = host.isNullOrEmpty(),
            confirmed = confirmed == Side.COMPUTER,
        ) {
            ClipAction(stringResource(R.string.clipboard_copy_to_phone), enabled = !host.isNullOrEmpty()) {
                manager.copyText(context.getString(R.string.clipboard_computer), host.orEmpty())
                confirmed = Side.COMPUTER
            }
        }
    }
}

@Composable
private fun ClipboardRow(
    icon: ImageVector,
    title: String,
    detail: String,
    empty: Boolean,
    confirmed: Boolean,
    actions: @Composable () -> Unit,
) {
    Column(Modifier.fillMaxWidth().rowSurface().padding(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(11.dp)) {
            Box(
                Modifier.size(28.dp).clip(peeringShapes.extraSmall).background(PeeringColors.ink.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) { Icon(icon, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(16.dp)) }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(title, style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
                    if (confirmed) Icon(AppIcons.check, contentDescription = null, tint = PeeringColors.accent, modifier = Modifier.size(14.dp))
                }
                Text(
                    detail,
                    style = PeeringText.caption,
                    color = if (empty) PeeringColors.tertiary else PeeringColors.muted,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) { actions() }
    }
}

@Composable
private fun ClipAction(title: String, prominent: Boolean = false, enabled: Boolean, onClick: () -> Unit) {
    Text(
        title,
        style = PeeringText.subheadline.copy(fontWeight = if (prominent) FontWeight.SemiBold else FontWeight.Medium),
        color = if (prominent) PeeringColors.onInk else PeeringColors.ink,
        maxLines = 1,
        modifier = Modifier
            .alpha(if (enabled) 1f else 0.4f)
            .clip(PillShape)
            .background(if (prominent) PeeringColors.ink else PeeringColors.ink.copy(alpha = 0.12f))
            .tappable(onClick, enabled = enabled)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    )
}

private const val CONFIRM_MILLIS = 1_500L
