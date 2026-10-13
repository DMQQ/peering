package pl.dmq.peering.background

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The POST_NOTIFICATIONS permission. It is asked for the first time a session starts, after a sentence saying why, and
 * again from the Settings toggle. Refusing costs the notifications only: the session itself runs as before.
 */
internal class NotificationPermission(
    private val context: Context,
    private val preferences: SharedPreferences,
) {
    private val explaining = MutableStateFlow(false)

    /** True while the explanation dialog is due. */
    val explanationShown: StateFlow<Boolean> = explaining.asStateFlow()

    /** Set by the activity that can show the system dialog, and cleared when it goes. */
    var launchSystemDialog: (() -> Unit)? = null

    fun isGranted(): Boolean = Build.VERSION.SDK_INT < PermissionPrompt.FIRST_SDK_WITH_PERMISSION ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun onSessionStarted(enabled: Boolean) {
        val step = PermissionPrompt.onFirstSession(Build.VERSION.SDK_INT, isGranted(), enabled, preferences.getBoolean(EXPLAINED, false))
        if (step != PermissionStep.ExplainThenAsk) return
        preferences.edit().putBoolean(EXPLAINED, true).apply()
        explaining.value = true
    }

    fun onExplanationAccepted() {
        explaining.value = false
        launchSystemDialog?.invoke()
    }

    fun onExplanationDeclined() {
        explaining.value = false
    }

    fun onNotificationsTurnedOn() {
        when (PermissionPrompt.onToggledOn(Build.VERSION.SDK_INT, isGranted(), preferences.getBoolean(REFUSED, false))) {
            PermissionStep.Ask -> launchSystemDialog?.invoke()
            PermissionStep.OpenSettings -> openAppNotificationSettings()
            PermissionStep.None, PermissionStep.ExplainThenAsk -> Unit
        }
    }

    fun onSystemDialogAnswered(granted: Boolean) {
        preferences.edit().putBoolean(REFUSED, !granted).apply()
    }

    private fun openAppNotificationSettings() {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    private companion object {
        const val EXPLAINED = "notification_permission_explained"
        const val REFUSED = "notification_permission_refused"
    }
}
