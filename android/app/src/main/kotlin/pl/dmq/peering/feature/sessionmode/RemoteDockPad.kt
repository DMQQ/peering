package pl.dmq.peering.feature.sessionmode

import android.view.OrientationEventListener
import android.view.View
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.changedToDown
import androidx.compose.ui.input.pointer.changedToUp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.remote.RemoteCanvasPresenter
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.sessionSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PillShape
import pl.dmq.peering.ui.theme.peeringShapes

private val PadShape = peeringShapes.large

/** The trackpad: an outlined field of dots that answers the fingers, with a corner button that gives it the whole screen. */
@Composable
fun RemoteDockPad(
    pad: RemoteCanvasPresenter,
    gestures: TrackpadGestures,
    fillsScreen: Boolean,
    onFillsScreen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var touch by remember { mutableStateOf<Offset?>(null) }
    var tap by remember { mutableStateOf<DotTap?>(null) }
    var taps by remember { mutableIntStateOf(0) }
    gestures.onTapped = { x, y -> tap = DotTap(Offset(x.toFloat(), y.toFloat()), ++taps) }
    FollowOrientation(gestures)
    DisposableEffect(gestures) { onDispose(gestures::cancel) }
    Box(modifier.clip(PadShape).border(1.dp, PeeringColors.ink.copy(alpha = 0.14f), PadShape)) {
        DotField(
            touch,
            tap,
            Modifier
                .fillMaxSize()
                .onSizeChanged { pad.onCanvasSized(it.width.toDouble(), it.height.toDouble()) }
                .pointerInput(gestures) {
                    awaitEachGesture {
                        try {
                            do {
                                val changes = awaitPointerEvent().changes
                                if (changes.any { it.isConsumed }) break
                                changes.forEach { change ->
                                    forward(gestures, change)
                                    change.consume()
                                }
                                touch = gestures.touch?.let { Offset(it.first.toFloat(), it.second.toFloat()) }
                            } while (changes.any { it.pressed })
                        } finally {
                            // A gesture that ends with fingers still recorded was cancelled or taken by a parent: let go.
                            if (gestures.fingerDown) gestures.cancel()
                            touch = null
                        }
                    }
                },
        )
        FullScreenToggle(fillsScreen, onFillsScreen, Modifier.align(Alignment.TopEnd).padding(8.dp))
    }
}

private fun forward(gestures: TrackpadGestures, change: PointerInputChange) {
    val id = change.id.value.toInt()
    val x = change.position.x.toDouble()
    val y = change.position.y.toDouble()
    when {
        change.changedToDown() -> gestures.down(id, x, y, change.uptimeMillis)
        change.changedToUp() -> gestures.up(id, x, y, change.uptimeMillis)
        change.positionChanged() -> gestures.move(id, x, y, change.uptimeMillis)
    }
}

/** The screen stays upright when the phone is turned past where it rotates, so without this every gesture ran backwards. */
@Composable
private fun FollowOrientation(gestures: TrackpadGestures) {
    val view = LocalView.current
    DisposableEffect(view, gestures) {
        val listener = object : OrientationEventListener(view.context) {
            override fun onOrientationChanged(degrees: Int) {
                val device = TrackpadOrientation.deviceQuarterTurns(degrees) ?: return
                gestures.orientation = TrackpadOrientation.of(device, view.screenQuarterTurns())
            }
        }
        if (listener.canDetectOrientation()) listener.enable()
        onDispose(listener::disable)
    }
}

/** Surface.ROTATION_90 is the screen turned with its top to the left, which is one counterclockwise quarter turn. */
private fun View.screenQuarterTurns(): Int = display?.rotation ?: 0

@Composable
private fun FullScreenToggle(fillsScreen: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val label = stringResource(if (fillsScreen) R.string.dock_exit_full_screen else R.string.dock_full_screen)
    Box(
        modifier
            .size(36.dp)
            .sessionSurface(PillShape)
            .tappable(onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(if (fillsScreen) SessionIcons.exitImmersive else SessionIcons.immersive, contentDescription = null, tint = PeeringColors.ink, modifier = Modifier.size(18.dp))
    }
}

