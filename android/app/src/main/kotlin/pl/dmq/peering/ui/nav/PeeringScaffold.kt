package pl.dmq.peering.ui.nav

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.navigation.NavHostController
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.peeringBackdrop

@Composable
fun PeeringScaffold(navController: NavHostController = rememberNavController()) {
    val currentRoute = navController.currentBackStackEntryAsState().value?.destination?.route
    Scaffold(
        modifier = Modifier.fillMaxSize().peeringBackdrop(),
        containerColor = PeeringColors.backdrop.copy(alpha = 0f),
        bottomBar = {
            Column {
                HorizontalDivider(color = PeeringColors.hairline)
                NavigationBar(containerColor = PeeringColors.backdrop) {
                    PeeringDestination.entries.forEach { destination ->
                        NavigationBarItem(
                            selected = currentRoute == destination.route,
                            onClick = { navigateTo(navController, destination) },
                            icon = { Icon(destination.icon, contentDescription = null) },
                            label = { Text(stringResource(destination.labelRes)) },
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = PeeringColors.accent,
                                selectedTextColor = PeeringColors.accent,
                                indicatorColor = PeeringColors.surface,
                                unselectedIconColor = PeeringColors.muted,
                                unselectedTextColor = PeeringColors.muted,
                            ),
                        )
                    }
                }
            }
        },
    ) { padding ->
        PeeringNavHost(navController = navController, contentPadding = padding)
    }
}

private fun navigateTo(navController: NavHostController, destination: PeeringDestination) {
    navController.navigate(destination.route) {
        popUpTo(navController.graph.startDestinationId) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}
