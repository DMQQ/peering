package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.KeyGroupShape
import pl.dmq.peering.ui.theme.KeyShape
import pl.dmq.peering.ui.theme.PeeringColors

private val keyFill = Color.White.copy(alpha = 0.10f)
private val keyBorder = Color.White.copy(alpha = 0.16f)
private const val DISABLED_ALPHA = 0.4f

/**
 * The keys a shell is told without typing, in one row: a button for everything else, esc, tab, ctrl-C, and the four
 * arrows as one joined group. Return is the send button of the input.
 */
@Composable
fun TerminalDeck(onMore: () -> Unit, send: (String) -> Unit, isEnabled: Boolean, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().background(PeeringColors.backdrop).alpha(if (isEnabled) 1f else DISABLED_ALPHA)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            MoreKey(onMore, isEnabled)
            NarrowKey(TerminalKeySpecs.escape, send, isEnabled)
            NarrowKey(TerminalKeySpecs.tab, send, isEnabled)
            NarrowKey(TerminalKeySpecs.interrupt, send, isEnabled)
            Row(Modifier.weight(1f).clip(KeyGroupShape), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                TerminalKeySpecs.arrows.forEach { ArrowKey(it, send, isEnabled, Modifier.weight(1f)) }
            }
        }
        HorizontalDivider(Modifier.align(Alignment.TopCenter), color = PeeringColors.hairline)
    }
}

private fun Modifier.keySurface(shape: Shape) = background(keyFill, shape).border(0.5.dp, keyBorder, shape)

@Composable
private fun MoreKey(onMore: () -> Unit, enabled: Boolean) {
    Box(
        Modifier.size(width = 36.dp, height = 44.dp).railPress(onMore, enabled, scale = 0.9f).keySurface(KeyGroupShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(TerminalGlyphs.ellipsis, stringResource(R.string.terminal_more_keys), tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun NarrowKey(key: TerminalKeySpec, send: (String) -> Unit, enabled: Boolean) {
    val label = stringResource(key.label)
    Box(
        Modifier.size(width = 38.dp, height = 44.dp).railPress({ send(key.bytes) }, enabled, scale = 0.88f)
            .keySurface(KeyShape).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(key.title, color = PeeringColors.ink, fontSize = 13.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

@Composable
private fun ArrowKey(key: TerminalKeySpec, send: (String) -> Unit, enabled: Boolean, modifier: Modifier) {
    val label = stringResource(key.label)
    Box(
        modifier.height(44.dp).railPress({ send(key.bytes) }, enabled, scale = 0.92f).background(keyFill)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(key.title, color = PeeringColors.ink, fontSize = 21.sp, fontWeight = FontWeight.Medium)
    }
}
