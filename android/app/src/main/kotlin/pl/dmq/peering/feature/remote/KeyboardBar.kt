package pl.dmq.peering.feature.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.blockTouches
import pl.dmq.peering.ui.kit.chipSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

/** What the keys under the keyboard send. Each key goes through the presenter so a latched modifier applies and is released. */
class KeyboardKeys(
    val latches: Map<StickyModifier, ModifierLatch>,
    val typed: String,
    val onHide: () -> Unit,
    val onModifier: (StickyModifier) -> Unit,
    val onKey: (Int) -> Unit,
    val onEnter: () -> Unit,
    val onDelete: () -> Unit,
)

/**
 * The card above the system keyboard: the line being typed, then the modifiers, Esc, Tab and Enter, then the arrows and
 * delete. The dock and the pointer are behind the keyboard, so these are the keys a phone keyboard lacks.
 */
@Composable
fun KeyboardBar(keys: KeyboardKeys, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth().chipSurface(peeringShapes.medium).blockTouches().padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        TypedLine(keys.typed)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CompactKey(SessionIcons.hideKeyboard, stringResource(R.string.remote_keyboard_hide), keys.onHide, filled = true, large = true)
            ModifierBar(keys.latches, keys.onModifier)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                CompactKey(SessionIcons.escape, stringResource(R.string.remote_key_escape), { keys.onKey(ESCAPE) })
                CompactKey(SessionIcons.tab, stringResource(R.string.remote_key_tab), { keys.onKey(TAB) })
            }
            Spacer(Modifier.weight(1f))
            CompactKey(SessionIcons.enter, stringResource(R.string.remote_key_enter), keys.onEnter, large = true)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally)) {
            CompactKey(SessionIcons.left, stringResource(R.string.remote_arrow_left), { keys.onKey(LEFT) })
            CompactKey(SessionIcons.up, stringResource(R.string.remote_arrow_up), { keys.onKey(UP) })
            CompactKey(SessionIcons.down, stringResource(R.string.remote_arrow_down), { keys.onKey(DOWN) })
            CompactKey(SessionIcons.right, stringResource(R.string.remote_arrow_right), { keys.onKey(RIGHT) })
            CompactKey(SessionIcons.delete, stringResource(R.string.remote_key_delete), keys.onDelete)
        }
    }
}

@Composable
private fun TypedLine(typed: String) {
    val shape = peeringShapes.extraSmall
    Box(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(PeeringColors.backdrop.copy(alpha = 0.55f))
            .border(1.dp, PeeringColors.ink.copy(alpha = 0.08f), shape)
            .heightIn(min = 38.dp)
            .padding(horizontal = 10.dp, vertical = 7.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        if (typed.isEmpty()) {
            Text(stringResource(R.string.remote_typing), style = TYPED_STYLE, color = PeeringColors.tertiary, maxLines = 1)
        } else {
            Text(typed.takeLast(TYPED_VISIBLE), style = TYPED_STYLE, color = PeeringColors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** One small key of the keyboard card. The filled one is white, the way the phone marks the key that closes the keyboard. */
@Composable
internal fun CompactKey(icon: ImageVector, label: String, onClick: () -> Unit, filled: Boolean = false, large: Boolean = false) {
    Box(
        Modifier
            .size(width = if (large) 48.dp else 40.dp, height = if (large) 44.dp else 36.dp)
            .clip(peeringShapes.extraSmall)
            .background(if (filled) PeeringColors.ink else PeeringColors.ink.copy(alpha = 0.1f))
            .tappable(onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = if (filled) PeeringColors.onInk else PeeringColors.ink, modifier = Modifier.size(22.dp))
    }
}

private val TYPED_STYLE = PeeringText.subheadline.copy(fontFamily = FontFamily.Monospace, fontSize = 15.sp)

private const val TYPED_VISIBLE = 60

internal const val ESCAPE = 53
internal const val TAB = 48
internal const val LEFT = 123
internal const val RIGHT = 124
internal const val DOWN = 125
internal const val UP = 126
