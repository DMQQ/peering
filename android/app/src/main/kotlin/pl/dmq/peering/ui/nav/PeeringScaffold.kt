package pl.dmq.peering.ui.nav

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.navigation.NavHostController
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import pl.dmq.peering.ui.kit.FloatingTabBar
import pl.dmq.peering.ui.kit.FloatingTabBarClearance
import pl.dmq.peering.ui.kit.TabBarItem
import pl.dmq.peering.ui.theme.peeringBackdrop

@Composable
fun PeeringScaffold(navController: NavHostController = rememberNavController()) {
    val currentRoute = navController.currentBackStackEntryAsState().value?.destination?.route
    val items = PeeringDestination.entries.map { TabBarItem(it.route, stringResource(it.labelRes), it.icon) }
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + FloatingTabBarClearance
    Box(Modifier.fillMaxSize().peeringBackdrop()) {
        PeeringNavHost(navController = navController, contentPadding = PaddingValues(top = top, bottom = bottom))
        FloatingTabBar(
            items = items,
            selectedKey = currentRoute ?: PeeringDestination.Connect.route,
            onSelect = { key -> navigateTo(navController, PeeringDestination.entries.first { it.route == key }) },
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }
}

private fun navigateTo(navController: NavHostController, destination: PeeringDestination) {
    navController.navigate(destination.route) {
        popUpTo(navController.graph.startDestinationId) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}
