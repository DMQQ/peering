package pl.dmq.peering.feature.scan

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.LifecycleResumeEffect
import pl.dmq.peering.MainActivity
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
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
    val requestCamera = {
        val host = context.findActivity() as? MainActivity
        host?.permissionRequests?.request(host, Manifest.permission.CAMERA) { result ->
            requested = true
            granted = result
            rationale = host.shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)
        }
    }
    LifecycleResumeEffect(Unit) {
        granted = context.hasCameraPermission()
        onPauseOrDispose { granted = context.hasCameraPermission() }
    }
    BackHandler(onBack = onClose)
    val permission = CameraPermissionState.of(granted, requested, rationale)
    LaunchedEffect(permission) {
        if (permission == CameraPermissionState.Unasked) requestCamera()
    }

    Box(modifier = modifier.fillMaxSize().background(PeeringColors.backdrop)) {
        when {
            unavailable -> ScanMessage(
                icon = AppIcons.camera,
                text = stringResource(R.string.scan_unavailable),
            )
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
            permission == CameraPermissionState.Rationale -> ScanMessage(
                icon = AppIcons.camera,
                text = stringResource(R.string.scan_rationale),
                action = ScanAction(stringResource(R.string.scan_allow)) { requestCamera() },
            )
            permission == CameraPermissionState.PermanentlyDenied -> ScanMessage(
                icon = AppIcons.camera,
                title = stringResource(R.string.scan_denied_title),
                text = stringResource(R.string.scan_denied),
                action = ScanAction(stringResource(R.string.scan_open_settings)) { context.openAppSettings() },
            )
        }
        ScanOverlay(notice = notice, onClose = onClose, showHint = permission == CameraPermissionState.Granted)
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
