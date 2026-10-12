package pl.dmq.peering.testing

import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberUpdatedState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.connect.ConnectPresenter
import pl.dmq.peering.feature.settings.TrustedHostStore

/** The Connect tab: which stage shows, connecting to a trusted computer, ending the session, and the tour. */
@Composable
internal fun ConnectBridge(
    stage: String,
    onboarding: Boolean,
    connect: ConnectPresenter,
    trusted: TrustedHostStore,
    scope: CoroutineScope,
    resetTour: () -> Unit,
    skipTour: () -> Unit,
    disconnect: () -> Unit,
) {
    val shownStage = rememberUpdatedState(stage)
    val shownTour = rememberUpdatedState(onboarding)
    BridgeRegistration("connect", connect) {
        TestBridge.Slot(
            state = { mapOf("connectStage" to shownStage.value, "onboarding" to shownTour.value) },
            actions = mapOf(
                "connect" to { arg ->
                    scope.launch {
                        val hostId = if (arg == "trusted") trusted.trustedHosts().firstOrNull()?.firstOrNull()?.id else arg
                        hostId?.let(connect::connect)
                    }
                },
                "disconnect" to { disconnect() },
                "onboarding" to { arg ->
                    if (arg == "reset") resetTour() else skipTour()
                },
            ),
        )
    }
}
