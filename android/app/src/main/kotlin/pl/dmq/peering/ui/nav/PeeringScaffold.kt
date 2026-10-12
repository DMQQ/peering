package pl.dmq.peering.ui.nav

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.navigation.NavHostController
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import pl.dmq.peering.ui.theme.peeringBackdrop

@Composable
fun PeeringScaffold(navController: NavHostController = rememberNavController()) {
    val currentRoute = navController.currentBackStackEntryAsState().value?.destination?.route
    val chrome = remember { RootChrome() }
    CompositionLocalProvider(LocalRootChrome provides chrome) {
        Scaffold(
            modifier = Modifier.fillMaxSize().peeringBackdrop(),
            containerColor = Color.Transparent,
            bottomBar = {
                AnimatedVisibility(
                    visible = chrome.navigationBarVisible,
                    enter = expandVertically(),
                    exit = shrinkVertically(),
                ) {
                    PeeringNavigationBar(
                        selected = PeeringDestination.entries.firstOrNull { it.route == currentRoute },
                        onSelect = { navigateTo(navController, it) },
                    )
                }
            },
        ) { innerPadding ->
            PeeringNavHost(navController = navController, modifier = Modifier.padding(innerPadding).consumeWindowInsets(innerPadding))
        }
    }
}

private fun navigateTo(navController: NavHostController, destination: PeeringDestination) {
    navController.navigate(destination.route) {
        popUpTo(navController.graph.startDestinationId) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}
