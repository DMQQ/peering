package pl.dmq.peering.feature.scan

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import pl.dmq.peering.R
import pl.dmq.peering.feature.pairing.inkButtonColors
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * The camera scanner. Shows the picture once the camera permission is granted, and asks for it, explains it, or sends
 * the person to Settings otherwise. [onCode] answers each new code; [onClose] runs once a code was used or the person
 * leaves.
 */
@Composable
fun QrScannerRoute(
    onCode: (String) -> ScanOutcome,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(context.hasCameraPermission()) }
    var requested by rememberSaveable { mutableStateOf(false) }
    var rationale by rememberSaveable { mutableStateOf(false) }
    var unavailable by remember { mutableStateOf(!context.hasCameraHardware()) }
    var notice by remember { mutableStateOf<ScanOutcome?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { result ->
        requested = true
        granted = result
        rationale = context.findActivity()?.shouldShowRequestPermissionRationale(Manifest.permission.CAMERA) == true
    }
    LifecycleResumeEffect(Unit) {
        granted = context.hasCameraPermission()
        onPauseOrDispose {}
    }
    val permission = CameraPermissionState.of(granted, requested, rationale)
    LaunchedEffect(permission) {
        if (permission == CameraPermissionState.Unasked) launcher.launch(Manifest.permission.CAMERA)
    }

    Box(modifier = modifier.fillMaxSize().background(PeeringColors.backdrop)) {
        when {
            unavailable -> Message(stringResource(R.string.scan_unavailable))
            permission == CameraPermissionState.Granted -> {
                CameraPreview(
                    onCode = { text ->
                        val outcome = onCode(text)
                        if (outcome == ScanOutcome.Used) onClose() else notice = outcome
                    },
                    onUnavailable = { unavailable = true },
                )
                ScanFrameGuide()
            }
            permission == CameraPermissionState.Rationale -> Message(
                text = stringResource(R.string.scan_rationale),
                action = stringResource(R.string.scan_allow),
                onAction = { launcher.launch(Manifest.permission.CAMERA) },
            )
            permission == CameraPermissionState.PermanentlyDenied -> Message(
                text = stringResource(R.string.scan_denied),
                action = stringResource(R.string.scan_open_settings),
                onAction = { context.openAppSettings() },
            )
        }
        ScannerBar(
            notice = notice,
            onClose = onClose,
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }
}

@Composable
private fun Message(text: String, action: String? = null, onAction: () -> Unit = {}) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(text = text, style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
        if (action != null) {
            Button(onClick = onAction, colors = inkButtonColors()) { Text(action) }
        }
    }
}

@Composable
private fun ScannerBar(notice: ScanOutcome?, onClose: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        when (notice) {
            ScanOutcome.NotAPairingCode -> Text(
                stringResource(R.string.scan_not_pairing_code),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.danger,
            )
            ScanOutcome.WrongCode -> Text(
                stringResource(R.string.scan_code_mismatch),
                style = MaterialTheme.typography.bodySmall,
                color = PeeringColors.danger,
            )
            ScanOutcome.Used, null -> Text(
                stringResource(R.string.scan_hint),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.ink,
            )
        }
        OutlinedButton(onClick = onClose) {
            Text(stringResource(R.string.scan_close), color = PeeringColors.ink)
        }
    }
}

private fun Context.hasCameraPermission(): Boolean =
    checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

private fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

private fun Context.openAppSettings() {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
    startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}
