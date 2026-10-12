package pl.dmq.peering.platform

import android.util.Log

/**
 * The platform layer's log. It writes nothing until the app turns it on for a debug build, so a release build never
 * logs addresses, service names or causes.
 */
object PlatformLog {
    @Volatile
    var enabled = false

    fun d(tag: String, message: () -> String) {
        if (enabled) Log.d(tag, message())
    }

    fun w(tag: String, message: () -> String, cause: Throwable? = null) {
        if (enabled) Log.w(tag, message(), cause)
    }
}
