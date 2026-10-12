package pl.dmq.peering.ui.kit

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import kotlinx.coroutines.launch
import pl.dmq.peering.ui.theme.ContinuousShape
import pl.dmq.peering.ui.theme.PeeringColors

private val sheetShape = ContinuousShape(38.dp)

/** A floating sheet as iOS 26 draws it: inset from the edges, rounded all round, rising on a spring and dragged down to dismiss. */
@Composable
fun PeeringSheet(onDismiss: () -> Unit, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        (LocalView.current.parent as? DialogWindowProvider)?.window?.setDimAmount(0f)
        val scope = rememberCoroutineScope()
        val shown = remember { Animatable(0f) }
        var height by remember { mutableIntStateOf(1) }
        var drag by remember { mutableFloatStateOf(0f) }
        LaunchedEffect(Unit) { shown.animateTo(1f, spring(dampingRatio = 0.9f, stiffness = 380f)) }
        fun close() = scope.launch {
            shown.animateTo(0f, spring(dampingRatio = 1f, stiffness = 500f))
            onDismiss()
        }
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.45f * shown.value))
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { close() },
        ) {
            Column(
                modifier = modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(WindowInsets.systemBars.union(WindowInsets.ime))
                    .padding(8.dp)
                    .fillMaxWidth()
                    .onSizeChanged { height = it.height }
                    .graphicsLayer { translationY = (1f - shown.value) * (height + 64.dp.toPx()) + drag.coerceAtLeast(0f) }
                    .draggable(
                        orientation = Orientation.Vertical,
                        state = rememberDraggableState { drag += it },
                        onDragStopped = { velocity ->
                            if (drag > height * 0.3f || velocity > 1400f) close() else drag = 0f
                        },
                    )
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                    .background(PeeringColors.sheet, sheetShape)
                    .border(1.dp, Color.White.copy(alpha = 0.08f), sheetShape),
                content = content,
            )
        }
    }
}
