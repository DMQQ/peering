package pl.dmq.peering.feature.remote

import android.view.SurfaceView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.changedToDown
import androidx.compose.ui.input.pointer.changedToUp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.viewinterop.AndroidView
import kotlin.math.roundToInt

/**
 * The picture, hosted in a SurfaceView, under pinch zoom and pan. Pointers are forwarded in untransformed canvas
 * pixels, so the presenter maps them through its own viewport.
 */
@Composable
fun RemoteCanvas(
    presenter: RemoteCanvasPresenter,
    surface: SurfaceListener,
    onTouch: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by presenter.state.collectAsState()
    Box(
        modifier = modifier
            .clipToBounds()
            .onSizeChanged { presenter.onCanvasSized(it.width.toDouble(), it.height.toDouble()) }
            .pointerInput(presenter, onTouch) { forwardPointers(presenter, onTouch) },
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    transformOrigin = TransformOrigin(0f, 0f)
                    scaleX = state.viewport.zoom.toFloat()
                    scaleY = state.viewport.zoom.toFloat()
                    translationX = state.viewport.panX.toFloat()
                    translationY = state.viewport.panY.toFloat()
                },
        ) {
            state.picture?.let { PictureSurface(it, surface) }
        }
    }
}

@Composable
private fun PictureSurface(fit: CanvasRect, surface: SurfaceListener) {
    AndroidView(
        modifier = Modifier.placedAt(fit),
        factory = { context ->
            SurfaceView(context).apply { holder.addCallback(PictureSurfaceCallback(surface)) }
        },
    )
}

private fun Modifier.placedAt(rect: CanvasRect): Modifier = layout { measurable, constraints ->
    val placeable = measurable.measure(Constraints.fixed(rect.width.roundToInt(), rect.height.roundToInt()))
    layout(constraints.maxWidth, constraints.maxHeight) {
        placeable.place(rect.left.roundToInt(), rect.top.roundToInt())
    }
}

private suspend fun PointerInputScope.forwardPointers(presenter: RemoteCanvasPresenter, onTouch: () -> Unit) {
    awaitPointerEventScope {
        while (true) {
            awaitPointerEvent().changes.forEach { change ->
                if (change.changedToDown()) onTouch()
                forwardChange(presenter, change)
                change.consume()
            }
        }
    }
}

private fun forwardChange(presenter: RemoteCanvasPresenter, change: PointerInputChange) {
    val id = change.id.value.toInt()
    val x = change.position.x.toDouble()
    val y = change.position.y.toDouble()
    val time = change.uptimeMillis
    when {
        change.changedToDown() -> presenter.onPointerDown(id, x, y, time)
        change.changedToUp() -> presenter.onPointerUp(id, x, y, time)
        change.positionChanged() -> presenter.onPointerMove(id, x, y, time)
    }
}
