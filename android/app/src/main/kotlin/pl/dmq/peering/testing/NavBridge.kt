package pl.dmq.peering.testing

import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import pl.dmq.peering.ui.nav.PeeringDestination
import pl.dmq.peering.ui.wiring.findActivity

/** The root tab on display, and the two ways the harness moves it: a tab switch and the system back. */
@Composable
internal fun NavBridge(currentRoute: String?, select: (PeeringDestination) -> Unit) {
    val route = rememberUpdatedState(currentRoute)
    val activity = LocalContext.current.findActivity() as? ComponentActivity
    BridgeRegistration("nav", activity) {
        TestBridge.Slot(
            state = { mapOf("tab" to route.value) },
            actions = mapOf(
                "tab" to { arg -> PeeringDestination.entries.firstOrNull { it.route == arg }?.let(select) },
                "back" to { activity?.onBackPressedDispatcher?.onBackPressed() },
            ),
        )
    }
}
