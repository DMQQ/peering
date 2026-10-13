package pl.dmq.peering

import android.app.Activity
import androidx.core.app.ActivityCompat

/**
 * Runtime permission requests that go straight through [ActivityCompat]. The activity-result registry numbers its requests above
 * 16 bits, which FragmentActivity (needed for the biometric prompt) refuses for permissions, ending the app with an exception.
 */
class PermissionRequests {
    private val waiting = mutableMapOf<Int, (Boolean) -> Unit>()
    private var next = FIRST_CODE

    fun request(activity: Activity, permission: String, onAnswer: (Boolean) -> Unit) {
        val code = next++.also { if (next > LAST_CODE) next = FIRST_CODE }
        waiting[code] = onAnswer
        ActivityCompat.requestPermissions(activity, arrayOf(permission), code)
    }

    fun onResult(requestCode: Int, grantResults: IntArray) {
        val answer = waiting.remove(requestCode) ?: return
        answer(grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED)
    }

    private companion object {
        const val FIRST_CODE = 0x2000
        const val LAST_CODE = 0x2FFF
    }
}
