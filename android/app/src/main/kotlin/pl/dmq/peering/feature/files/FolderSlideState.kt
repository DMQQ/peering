package pl.dmq.peering.feature.files

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.GraphicsLayerScope
import androidx.compose.ui.unit.IntSize

/**
 * One list moved aside and eased back when the folder changes, so the direction is the one known at that moment. A
 * transition between two list views would give a leaving view the direction it was drawn with, and every second move
 * would slide the wrong way. Only the list takes [layer]: the bars around it stay where they are.
 */
internal class FolderSlideState(private val offset: Animatable<Float, *>) {
    var width by mutableFloatStateOf(0f)
        private set

    val onWidth: (IntSize) -> Unit = { width = it.width.toFloat() }

    val layer: GraphicsLayerScope.() -> Unit = {
        translationX = offset.value
        alpha = if (offset.value == 0f) 1f else FolderSlide.MOVING_ALPHA
    }

    suspend fun slide(from: String?, to: String?) {
        if (width <= 0f) return
        offset.snapTo(FolderSlide.startOffset(from, to, width))
        offset.animateTo(0f, tween(FolderSlide.DURATION_MS, easing = LinearOutSlowInEasing))
    }
}

@Composable
internal fun rememberFolderSlide(path: String?): FolderSlideState {
    val state = remember { FolderSlideState(Animatable(0f)) }
    var shown by remember { mutableStateOf(path) }
    LaunchedEffect(path) {
        val previous = shown
        shown = path
        if (previous != null && previous != path) state.slide(previous, path)
    }
    return state
}
