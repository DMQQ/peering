package pl.dmq.peering.feature.remote

import android.os.Build
import android.view.View
import android.view.Window
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import pl.dmq.peering.ui.wiring.findActivity

/**
 * Makes the window fit a live session while this is composed: system bars hidden (a swipe from the edge shows them for
 * a moment), the picture allowed under the display cutout, and the screen kept on. Everything is put back on leaving.
 */
@Composable
fun SessionWindow() {
    val view = LocalView.current
    DisposableEffect(view) {
        val applied = view.context.findActivity()?.window?.let { AppliedSessionWindow.enter(it, view) }
        onDispose { applied?.restore() }
    }
}

private class AppliedSessionWindow private constructor(
    private val window: Window,
    private val controller: WindowInsetsControllerCompat,
    private val previousBehavior: Int,
    private val previousCutoutMode: Int,
) {
    fun restore() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setCutoutMode(window, previousCutoutMode)
        controller.systemBarsBehavior = previousBehavior
        controller.show(WindowInsetsCompat.Type.systemBars())
    }

    companion object {
        fun enter(window: Window, view: View): AppliedSessionWindow {
            val controller = WindowCompat.getInsetsController(window, view)
            val applied = AppliedSessionWindow(
                window = window,
                controller = controller,
                previousBehavior = controller.systemBarsBehavior,
                previousCutoutMode = cutoutMode(window),
            )
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
            setCutoutMode(window, SHORT_EDGES)
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            return applied
        }

        private const val SHORT_EDGES = 1

        private fun cutoutMode(window: Window): Int =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) window.attributes.layoutInDisplayCutoutMode else 0

        private fun setCutoutMode(window: Window, mode: Int) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                window.attributes = window.attributes.apply { layoutInDisplayCutoutMode = mode }
            }
        }
    }
}
