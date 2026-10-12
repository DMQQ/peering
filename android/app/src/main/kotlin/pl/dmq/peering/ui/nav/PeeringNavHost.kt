package pl.dmq.peering.ui.nav

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import pl.dmq.peering.ui.theme.PeeringMotion

/** Tabs are peers, so they change with Material's fade through: the old one fades out, then the new one fades and scales in. */
@Composable
fun PeeringNavHost(navController: NavHostController, modifier: Modifier = Modifier) {
    NavHost(
        navController = navController,
        startDestination = PeeringDestination.Connect.route,
        modifier = modifier,
        enterTransition = { fadeThroughIn },
        exitTransition = { fadeThroughOut },
        popEnterTransition = { fadeThroughIn },
        popExitTransition = { fadeThroughOut },
    ) {
        PeeringDestination.entries.forEach { destination ->
            composable(destination.route) { ScreenRegistry.slotFor(destination)() }
        }
    }
}

private val fadeThroughIn: EnterTransition =
    fadeIn(PeeringMotion.fadeThroughIn) + scaleIn(PeeringMotion.fadeThroughIn, initialScale = 0.92f)

private val fadeThroughOut: ExitTransition = fadeOut(PeeringMotion.fadeThroughOut)
