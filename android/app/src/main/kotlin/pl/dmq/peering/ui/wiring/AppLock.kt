package pl.dmq.peering.ui.wiring

import android.content.Context
import android.content.SharedPreferences
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/** Whether opening Peering asks for the device's own unlock, kept in the preferences the rest of the app uses. */
internal class AppLock(private val preferences: SharedPreferences) {
    fun isEnabled(): Boolean = preferences.getBoolean(KEY, false)

    fun setEnabled(enabled: Boolean) {
        PreferenceWrites.shared.save(preferences) { putBoolean(KEY, enabled) }
    }

    private companion object {
        const val KEY = "require_device_unlock"
    }
}

/** The system's own prompt: a fingerprint or face when the device has one enrolled, otherwise its PIN, pattern or password. */
internal object DeviceUnlock {
    private const val AUTHENTICATORS = BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL

    fun isAvailable(context: Context): Boolean =
        BiometricManager.from(context).canAuthenticate(AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS

    fun prompt(activity: FragmentActivity, title: String, onResult: (Boolean) -> Unit) {
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = onResult(true)

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) = onResult(false)
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setAllowedAuthenticators(AUTHENTICATORS)
            .build()
        BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback).authenticate(info)
    }
}
