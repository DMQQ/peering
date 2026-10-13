package pl.dmq.peering.feature.remote

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.SessionIcons

/** What the pointer controls send: Back and Enter are keys, the joystick has its own actions. */
class PointerActions(
    val onBack: () -> Unit,
    val onEnter: () -> Unit,
    val joystick: JoystickActions,
    val pointWidth: Double,
    val pointHeight: Double,
)

/** Portrait: Back, the joystick and Enter in one row, centred on the picture's middle. Both keys share one frame so the stick lands on the centre. */
@Composable
fun PointerRow(actions: PointerActions, speedText: String?, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ChromeMetrics.panelGap)) {
        Box(Modifier.size(ChromeMetrics.quickKeySize), contentAlignment = Alignment.Center) { BackKey(actions.onBack) }
        Joystick(actions.joystick, actions.pointWidth, actions.pointHeight, speedText)
        Box(Modifier.size(ChromeMetrics.quickKeySize), contentAlignment = Alignment.Center) { EnterKey(actions.onEnter) }
    }
}

/** Landscape: Enter over the joystick's width, with Back at the joystick's side, in the corner the thumb rests on. */
@Composable
fun PointerColumn(actions: PointerActions, speedText: String?, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(ChromeMetrics.panelGap)) {
        Box(Modifier.width(ChromeMetrics.joystickRadius * 2), contentAlignment = Alignment.Center) { EnterKey(actions.onEnter) }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(ChromeMetrics.panelGap)) {
            BackKey(actions.onBack)
            Joystick(actions.joystick, actions.pointWidth, actions.pointHeight, speedText)
        }
    }
}

@Composable
private fun EnterKey(onClick: () -> Unit) {
    QuickKey(SessionIcons.enter, stringResource(R.string.remote_key_enter), ChromeMetrics.quickKeySize, onClick)
}

@Composable
private fun BackKey(onClick: () -> Unit) {
    QuickKey(SessionIcons.left, stringResource(R.string.remote_key_back), ChromeMetrics.backKeySize, onClick)
}
