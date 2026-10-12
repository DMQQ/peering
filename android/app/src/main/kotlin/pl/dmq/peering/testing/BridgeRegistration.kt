package pl.dmq.peering.testing

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import pl.dmq.peering.BuildConfig

/** Offers [slot] to the debug harness while this is in the composition. Does nothing in a release build. */
@Composable
internal fun BridgeRegistration(name: String, vararg keys: Any?, slot: () -> TestBridge.Slot) {
    if (!BuildConfig.DEBUG) return
    DisposableEffect(name, *keys) {
        val remove = TestBridge.register(name, slot())
        onDispose(remove)
    }
}
