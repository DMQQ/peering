package pl.dmq.peering.ui.wiring

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.res.Configuration

/** Tells [onPressure] when the system is short of memory, for the live session to drop what it only keeps as scrollback. */
internal class MemoryPressure(context: Context, private val onPressure: () -> Unit) {
    init {
        context.registerComponentCallbacks(
            object : ComponentCallbacks2 {
                override fun onTrimMemory(level: Int) {
                    if (shouldTrim(level)) onPressure()
                }

                override fun onConfigurationChanged(newConfig: Configuration) = Unit

                @Deprecated("Replaced by onTrimMemory", ReplaceWith("onTrimMemory"))
                override fun onLowMemory() = onPressure()
            },
        )
    }

    companion object {
        /**
         * While running, only the low and critical steps matter; once the app is in the background the system is
         * reclaiming it, and every step from there on counts. The UI-hidden step fires on every backgrounding and is
         * not pressure.
         */
        fun shouldTrim(level: Int): Boolean =
            level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW ||
                level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL ||
                level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND
    }
}
