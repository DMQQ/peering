package pl.dmq.peering.feature.remote.dictation

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import pl.dmq.peering.MainActivity

/** A dictation tied to the screen it is on: listening stops when the screen goes. */
@Composable
fun rememberVoiceDictation(): VoiceDictation {
    val context = LocalContext.current
    val dictation = remember(context) {
        VoiceDictation(
            context = context.applicationContext,
            hasMicrophone = { context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED },
            askMicrophone = { answer ->
                val host = context.findActivity() as? MainActivity
                if (host == null) answer(false) else host.permissionRequests.request(host, Manifest.permission.RECORD_AUDIO, answer)
            },
        )
    }
    DisposableEffect(dictation) { onDispose(dictation::cancel) }
    return dictation
}

private fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
