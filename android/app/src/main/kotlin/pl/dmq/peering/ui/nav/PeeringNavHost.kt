package pl.dmq.peering.ui.nav

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import pl.dmq.peering.ui.theme.peeringBackdrop

/** Tabs are peers and switch instantly. Every animation tried here, a fade through included, flashed a gap between the two screens. */
@Composable
fun PeeringNavHost(navController: NavHostController, modifier: Modifier = Modifier) {
    NavHost(
        navController = navController,
        startDestination = PeeringDestination.Connect.route,
        modifier = modifier,
        enterTransition = { EnterTransition.None },
        exitTransition = { ExitTransition.None },
        popEnterTransition = { EnterTransition.None },
        popExitTransition = { ExitTransition.None },
    ) {
        PeeringDestination.entries.forEach { destination ->
            // Opaque, because the outgoing tab stays composed for a frame or two and showed through the incoming one.
            composable(destination.route) {
                Box(Modifier.fillMaxSize().peeringBackdrop()) { ScreenRegistry.slotFor(destination)() }
            }
        }
    }
}
