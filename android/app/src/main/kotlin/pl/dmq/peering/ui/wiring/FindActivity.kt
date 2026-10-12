package pl.dmq.peering.ui.wiring

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper

/** The activity a context belongs to, or null when there is none, as for an application context. */
internal fun Context.findActivity(): Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}
