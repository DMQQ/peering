package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/**
 * fn and F1 to F12. With fn off a key sends the action printed on a Mac's top row where there is one (brightness,
 * volume, media), and the F key itself otherwise. Latch fn to send the F key itself, so Cmd then F5 is VoiceOver.
 */
@Composable
internal fun FunctionKeyGrid(actions: ShortcutsActions) {
    var fnLatched by rememberSaveable { mutableStateOf(false) }
    val icons = SessionIcons.topRow
    val fnDescription = stringResource(R.string.remote_fn_description)
    val chips = buildList {
        add(
            KeyChip(
                "fn",
                { Text("fn", style = PeeringText.subheadlineMedium, color = if (fnLatched) PeeringColors.accent else PeeringColors.ink) },
                fnDescription,
            ) { fnLatched = !fnLatched },
        )
        FunctionKey.entries.forEachIndexed { index, key ->
            val icon = icons[index]
            val printsAction = !fnLatched && icon != null
            add(
                KeyChip(
                    key.name,
                    {
                        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            if (printsAction && icon != null) Icon(icon, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
                            Text(
                                key.name,
                                style = PeeringText.subheadlineMedium.copy(fontSize = if (printsAction) 10.sp else 15.sp, fontWeight = FontWeight.Medium),
                                color = if (printsAction) PeeringColors.muted else PeeringColors.ink,
                            )
                        }
                    },
                    key.name,
                ) { if (printsAction) actions.onTopRowAction(key.macKeyCode) else actions.onKey(key.macKeyCode, 0L) },
            )
        }
    }
    KeyChipGrid(chips)
}
