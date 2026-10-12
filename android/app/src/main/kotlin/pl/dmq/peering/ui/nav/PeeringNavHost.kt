package pl.dmq.peering.ui.nav

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable

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
            composable(destination.route) { ScreenRegistry.slotFor(destination)() }
        }
    }
}
