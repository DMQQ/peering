package pl.dmq.peering.feature.remote

import android.content.res.Configuration
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringShapes

/** Everything drawn over the picture: the status pill, the connection banner, the toolbar and the keyboard rows. */
@Composable
fun RemoteChrome(
    shown: Boolean,
    overlay: SessionOverlayState,
    zoomPercent: Int?,
    toolbar: List<ToolbarAction>,
    keyboardShown: Boolean,
    mode: InputMode,
    latches: Map<StickyModifier, ModifierLatch>,
    onReveal: () -> Unit,
    onFit: () -> Unit,
    onRetry: () -> Unit,
    onDisconnect: () -> Unit,
    onToolbar: (ToolbarAction) -> Unit,
    onFunctionKey: (FunctionKey) -> Unit,
    onEditingKey: (EditingKey) -> Unit,
    onModifier: (StickyModifier) -> Unit,
    modifier: Modifier = Modifier,
) {
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val insets = WindowInsets.systemBars.union(WindowInsets.displayCutout)
    Box(modifier = modifier.fillMaxSize().windowInsetsPadding(insets).padding(8.dp)) {
        AnimatedVisibility(
            visible = shown,
            modifier = Modifier.align(Alignment.TopCenter),
            enter = fadeIn() + slideInVertically { -it / 2 },
            exit = fadeOut() + slideOutVertically { -it / 2 },
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SessionOverlay(
                    state = overlay,
                    zoomPercent = zoomPercent,
                    onFit = onFit,
                    onDisconnect = onDisconnect,
                )
            }
        }
        AnimatedVisibility(
            visible = !shown,
            modifier = Modifier.align(Alignment.TopCenter),
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            RevealHandle(onReveal)
        }
        AnimatedVisibility(
            visible = shown && landscape,
            modifier = Modifier.align(Alignment.CenterEnd),
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            SessionToolbar(toolbar, keyboardShown, mode, vertical = true, onAction = onToolbar)
        }
        Column(
            modifier = Modifier.align(Alignment.BottomCenter),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SessionSnackbar(state = overlay, onRetry = onRetry)
            if (keyboardShown) {
                Surface(shape = peeringShapes.large, color = PeeringColors.containerHigh, shadowElevation = 6.dp) {
                    Column(
                        modifier = Modifier.padding(vertical = 8.dp, horizontal = 6.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        FunctionKeyRow(onKey = onFunctionKey, onEditingKey = onEditingKey)
                        ModifierBar(latches = latches, onTap = onModifier)
                    }
                }
            }
            AnimatedVisibility(visible = shown && !landscape, enter = fadeIn(), exit = fadeOut()) {
                SessionToolbar(toolbar, keyboardShown, mode, vertical = false, onAction = onToolbar)
            }
        }
    }
}

@Composable
private fun RevealHandle(onReveal: () -> Unit) {
    SmallFloatingActionButton(
        onClick = onReveal,
        containerColor = PeeringColors.containerHigh,
        contentColor = PeeringColors.ink,
    ) {
        Icon(imageVector = AppIcons.expand, contentDescription = stringResource(R.string.remote_show_controls))
    }
}
