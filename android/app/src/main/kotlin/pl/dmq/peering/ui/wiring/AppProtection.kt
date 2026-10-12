package pl.dmq.peering.ui.wiring

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.fragment.app.FragmentActivity
import pl.dmq.peering.MainActivity
import pl.dmq.peering.R
import pl.dmq.peering.feature.connect.AppProtection

/** The Connect card's switch: turning it on asks for the device's unlock first, so it cannot lock the owner out. */
@Composable
internal fun rememberAppProtection(): AppProtection {
    val context = LocalContext.current
    val reason = stringResource(R.string.connect_protect_reason)
    val lock = remember(context) { AppLock(context.getSharedPreferences(MainActivity.PREFERENCES_NAME, Context.MODE_PRIVATE)) }
    var enabled by remember { mutableStateOf(lock.isEnabled()) }
    val available = remember(context) { DeviceUnlock.isAvailable(context) }
    return AppProtection(enabled, available) { requested ->
        val activity = context.findActivity() as? FragmentActivity
        fun store(on: Boolean) {
            lock.setEnabled(on)
            enabled = on
            activity?.let { ScreenSecurity.apply(it.window, ScreenSecurity.hidesContent(on, lockShowing = false, sessionOnScreen = false)) }
        }
        if (!requested || activity == null) {
            store(false)
        } else {
            DeviceUnlock.prompt(activity, reason) { confirmed ->
                if (confirmed) store(true)
            }
        }
    }
}
