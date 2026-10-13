package pl.dmq.peering

import android.util.Log

/** The one place the app logs from. A release build writes nothing, so the log never carries addresses or causes. */
internal object DebugLog {
    fun d(tag: String, message: () -> String) {
        if (BuildConfig.DEBUG) Log.d(tag, message())
    }

    fun w(tag: String, message: () -> String, cause: Throwable? = null) {
        if (BuildConfig.DEBUG) Log.w(tag, message(), cause)
    }
}
