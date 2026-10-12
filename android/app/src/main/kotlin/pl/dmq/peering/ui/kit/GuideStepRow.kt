package pl.dmq.peering.ui.kit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

enum class GuideStepState { Done, Current, Pending }

/** One step of a guide: a numbered marker joined to the next by a line, with the step's own controls under its title while it is the one in play. */
@Composable
fun GuideStepRow(
    number: Int,
    state: GuideStepState,
    title: String,
    modifier: Modifier = Modifier,
    isLast: Boolean = false,
    content: @Composable ColumnScope.() -> Unit = {},
) {
    Row(modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Column(Modifier.width(30.dp).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
            Marker(number, state)
            if (!isLast) {
                Box(
                    Modifier
                        .width(1.dp)
                        .weight(1f)
                        .background(Color.White.copy(alpha = if (state == GuideStepState.Done) 0.35f else 0.12f)),
                )
            }
        }
        Column(Modifier.weight(1f).padding(bottom = if (isLast) 0.dp else 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.heightIn(min = 30.dp), contentAlignment = Alignment.CenterStart) {
                Text(
                    title,
                    style = PeeringText.headline,
                    color = if (state == GuideStepState.Pending) PeeringColors.muted else PeeringColors.ink,
                )
            }
            content()
        }
    }
}

@Composable
private fun Marker(number: Int, state: GuideStepState) {
    when (state) {
        GuideStepState.Done -> Box(Modifier.size(30.dp).background(PeeringColors.ink, CircleShape), contentAlignment = Alignment.Center) {
            Icon(Symbols.checkmark, null, tint = PeeringColors.onInk, modifier = Modifier.size(16.dp))
        }
        GuideStepState.Current -> Box(
            Modifier.size(30.dp).background(PeeringColors.accent.copy(alpha = 0.18f), CircleShape).border(2.dp, PeeringColors.accent, CircleShape),
            contentAlignment = Alignment.Center,
        ) { Text("$number", style = PeeringText.subheadline.copy(fontWeight = FontWeight.Bold), color = PeeringColors.ink) }
        GuideStepState.Pending -> Box(
            Modifier.size(30.dp).border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape),
            contentAlignment = Alignment.Center,
        ) { Text("$number", style = PeeringText.subheadline.copy(fontWeight = FontWeight.Medium), color = PeeringColors.muted) }
    }
}

/** The sentence under a step's title. */
@Composable
fun StepDetail(text: String, modifier: Modifier = Modifier) {
    Text(text, style = PeeringText.subheadline, color = PeeringColors.muted, modifier = modifier)
}
