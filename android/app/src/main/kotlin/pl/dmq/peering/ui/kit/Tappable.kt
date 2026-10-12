package pl.dmq.peering.ui.kit

import androidx.compose.foundation.clickable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role

/** A click with Android's ripple, bounded by whatever shape the caller clipped to before this. A null [onClick] leaves the element inert. */
fun Modifier.tappable(onClick: (() -> Unit)?, enabled: Boolean = true, role: Role = Role.Button): Modifier =
    if (onClick == null) this else clickable(enabled = enabled, role = role, onClick = onClick)

/** Takes every touch that lands on this element, gaps included, so it never reaches the picture drawn behind it. */
fun Modifier.blockTouches(): Modifier = pointerInput(Unit) {
    awaitPointerEventScope {
        while (true) awaitPointerEvent().changes.forEach { it.consume() }
    }
}
