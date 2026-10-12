package pl.dmq.peering.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.kit.pressable

/** The filled capsule beside a quiet one: white with a black label, 44 tall as the iPhone's `borderedProminent` draws it. */
@Composable
fun InkButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = modifier
            .defaultMinSize(minHeight = 44.dp)
            .pressable(onClick, enabled = enabled, scale = 0.97f)
            .clip(CircleShape)
            .background(if (enabled) PeeringColors.ink else Color.White.copy(alpha = 0.16f))
            .padding(horizontal = 20.dp),
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CompositionLocalProvider(
            LocalContentColor provides (if (enabled) PeeringColors.onInk else Color.White.copy(alpha = 0.55f)),
            LocalTextStyle provides PeeringText.subheadlineSemibold,
        ) { content() }
    }
}

/** A quiet capsule: outlined, white label. */
@Composable
fun QuietButton(onClick: () -> Unit, modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = modifier
            .defaultMinSize(minHeight = 44.dp)
            .pressable(onClick, scale = 0.97f)
            .clip(CircleShape)
            .border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape)
            .padding(horizontal = 20.dp),
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CompositionLocalProvider(
            LocalContentColor provides PeeringColors.ink,
            LocalTextStyle provides PeeringText.subheadlineSemibold,
        ) { content() }
    }
}
