package pl.dmq.peering.ui.wiring

import android.view.Window
import android.view.WindowManager
import pl.dmq.peering.BuildConfig

/** When the window must stay out of screenshots and the recents thumbnail, and when a set app lock can no longer work. */
internal object ScreenSecurity {
    /** The recents thumbnail is taken before the lock engages, so a window under an enabled lock is hidden throughout. */
    fun hidesContent(lockEnabled: Boolean, lockShowing: Boolean, sessionOnScreen: Boolean): Boolean =
        lockEnabled || lockShowing || sessionOnScreen

    /** The user asked for a lock but the device no longer has a screen lock to back it. */
    fun lockLapsed(lockEnabled: Boolean, deviceLockAvailable: Boolean): Boolean = lockEnabled && !deviceLockAvailable

    /** Debug builds stay capturable so the test harness can take screenshots. */
    fun apply(window: Window, hidden: Boolean) {
        if (BuildConfig.DEBUG) return
        if (hidden) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
}
