package pl.dmq.peering.ui.kit

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

private val trackWidth = 64.dp
private val trackHeight = 28.dp
private val knobWidth = 40.dp
private val knobHeight = 24.dp

/** The iOS 26 switch: a wide white pill riding a 64 by 28 track, the accent when on. */
@Composable
fun PeeringSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val travel = trackWidth - knobWidth - 4.dp
    val knobOffset by animateDpAsState(if (checked) travel + 2.dp else 2.dp, spring(dampingRatio = 0.8f, stiffness = 380f), label = "knob")
    val track by animateColorAsState(if (checked) PeeringColors.accent else Color(0xFF39393D), label = "track")
    Box(
        modifier = modifier
            .alpha(if (enabled) 1f else 0.4f)
            .width(trackWidth)
            .height(trackHeight)
            .semantics { role = Role.Switch; toggleableState = ToggleableState(checked) }
            .pressable({ onCheckedChange(!checked) }, enabled = enabled, scale = 0.97f, role = Role.Switch)
            .clip(CircleShape)
            .background(track),
        contentAlignment = Alignment.CenterStart,
    ) {
        Box(
            Modifier
                .offset(x = knobOffset)
                .size(knobWidth, knobHeight)
                .shadow(2.dp, CircleShape)
                .background(Color.White, CircleShape),
        )
    }
}
