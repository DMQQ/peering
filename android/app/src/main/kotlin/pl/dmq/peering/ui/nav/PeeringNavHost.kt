package pl.dmq.peering.ui.nav

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable

@Composable
fun PeeringNavHost(
    navController: NavHostController,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    NavHost(
        navController = navController,
        startDestination = PeeringDestination.Connect.route,
        modifier = modifier.padding(contentPadding),
    ) {
        PeeringDestination.entries.forEach { destination ->
            composable(destination.route) { ScreenRegistry.slotFor(destination)() }
        }
    }
}
