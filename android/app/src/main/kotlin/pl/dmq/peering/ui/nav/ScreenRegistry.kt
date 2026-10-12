package pl.dmq.peering.ui.nav

import androidx.compose.runtime.Composable

typealias ScreenSlot = @Composable () -> Unit

// Feature packages set every slot at startup, before the first frame; navigation files never change.
object ScreenRegistry {
    lateinit var connect: ScreenSlot
    lateinit var sessions: ScreenSlot
    lateinit var settings: ScreenSlot

    fun slotFor(destination: PeeringDestination): ScreenSlot = when (destination) {
        PeeringDestination.Connect -> connect
        PeeringDestination.Sessions -> sessions
        PeeringDestination.Settings -> settings
    }
}
