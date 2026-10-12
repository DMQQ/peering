package pl.dmq.peering.ui.nav

import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.ui.theme.PeeringColors

/** The root tabs as Material's bottom navigation: a dark surface and one blue indicator behind the selected tab. */
@Composable
fun PeeringNavigationBar(selected: PeeringDestination?, onSelect: (PeeringDestination) -> Unit, modifier: Modifier = Modifier) {
    NavigationBar(modifier = modifier, containerColor = PeeringColors.container, contentColor = PeeringColors.ink) {
        PeeringDestination.entries.forEach { destination ->
            val isSelected = destination == selected
            val label = stringResource(destination.labelRes)
            NavigationBarItem(
                selected = isSelected,
                onClick = { onSelect(destination) },
                icon = { Icon(if (isSelected) destination.selectedIcon else destination.icon, contentDescription = null) },
                label = { Text(label) },
                colors = NavigationBarItemDefaults.colors(
                    selectedIconColor = PeeringColors.ink,
                    selectedTextColor = PeeringColors.ink,
                    indicatorColor = PeeringColors.selectedIndicator,
                    unselectedIconColor = PeeringColors.muted,
                    unselectedTextColor = PeeringColors.muted,
                ),
            )
        }
    }
}
