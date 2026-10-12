package pl.dmq.peering.ui.nav

import androidx.compose.runtime.Composable

typealias ScreenSlot = @Composable () -> Unit

// Feature packages replace a slot at startup; navigation files never change.
object ScreenRegistry {
    var connect: ScreenSlot = { ConnectPlaceholder() }
    var sessions: ScreenSlot = { SessionsPlaceholder() }
    var settings: ScreenSlot = { SettingsPlaceholder() }

    fun slotFor(destination: PeeringDestination): ScreenSlot = when (destination) {
        PeeringDestination.Connect -> connect
        PeeringDestination.Sessions -> sessions
        PeeringDestination.Settings -> settings
    }
}
