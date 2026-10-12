package pl.dmq.peering.ui.nav

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import pl.dmq.peering.ui.kit.FadeThroughEnter
import pl.dmq.peering.ui.kit.FadeThroughExit

/** Tabs are peers, so they only crossfade: the old one fades out, then the new one fades in, with no scale or movement. */
@Composable
fun PeeringNavHost(navController: NavHostController, modifier: Modifier = Modifier) {
    NavHost(
        navController = navController,
        startDestination = PeeringDestination.Connect.route,
        modifier = modifier,
        enterTransition = { FadeThroughEnter },
        exitTransition = { FadeThroughExit },
        popEnterTransition = { FadeThroughEnter },
        popExitTransition = { FadeThroughExit },
    ) {
        PeeringDestination.entries.forEach { destination ->
            composable(destination.route) { ScreenRegistry.slotFor(destination)() }
        }
    }
}
