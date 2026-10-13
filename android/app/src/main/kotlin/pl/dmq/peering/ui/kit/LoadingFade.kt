package pl.dmq.peering.ui.kit

import androidx.compose.animation.core.Animatable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import kotlinx.coroutines.delay

/** Invisible for [Motion.LOADING_DELAY_MS], then fades in, so a state that resolves quickly never shows a flash of placeholder. */
fun Modifier.loadingFade(): Modifier = composed {
    val shown = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        delay(Motion.LOADING_DELAY_MS)
        shown.animateTo(1f, Motion.standard())
    }
    graphicsLayer { alpha = shown.value }
}
