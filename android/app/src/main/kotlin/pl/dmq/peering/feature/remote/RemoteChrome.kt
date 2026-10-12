package pl.dmq.peering.feature.remote

import android.content.res.Configuration
import androidx.compose.animation.AnimatedVisibility
import pl.dmq.peering.ui.kit.Motion
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.SessionIcons

/**
 * Everything drawn over the picture: what the picture says while it has none, the chrome in the arrangement the phone's
 * orientation calls for, and in immersive mode the one button that brings the chrome back.
 */
@Composable
fun RemoteChrome(
    state: ChromeState,
    handlers: ChromeHandlers,
    panel: @Composable (SessionPanel) -> Unit,
    modifier: Modifier = Modifier,
) {
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val insets = WindowInsets.systemBars.union(WindowInsets.displayCutout)
    Box(modifier.fillMaxSize().windowInsetsPadding(insets)) {
        PictureStatus(state.overlay.picture, handlers.onRetry, Modifier.align(Alignment.Center))
        AnimatedVisibility(visible = state.shown, enter = Motion.enter, exit = Motion.leave) {
            if (landscape) LandscapeChrome(state, handlers, panel) else PortraitChrome(state, handlers, panel)
        }
        AnimatedVisibility(
            visible = state.immersive && !state.shown,
            modifier = Modifier.align(Alignment.TopEnd).padding(ChromeMetrics.edgeInset),
            enter = Motion.enter,
            exit = Motion.leave,
        ) {
            CircleGlassButton(SessionIcons.exitImmersive, stringResource(R.string.remote_show_controls), handlers.onReveal)
        }
    }
}

@Composable
internal fun wheelLabel(state: ChromeState): String =
    stringResource(if (state.interaction == InputMode.OBSERVE) R.string.remote_wheel_zoom else R.string.remote_wheel_scroll)
