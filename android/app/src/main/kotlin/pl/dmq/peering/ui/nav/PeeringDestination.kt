package pl.dmq.peering.ui.nav

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.ui.graphics.vector.ImageVector
import pl.dmq.peering.R

enum class PeeringDestination(
    val route: String,
    @StringRes val labelRes: Int,
    val icon: ImageVector,
    val selectedIcon: ImageVector,
) {
    Connect("connect", R.string.nav_connect, Icons.Outlined.Devices, Icons.Filled.Devices),
    Sessions("sessions", R.string.nav_sessions, Icons.Outlined.Schedule, Icons.Filled.Schedule),
    Settings("settings", R.string.nav_settings, Icons.Outlined.Settings, Icons.Filled.Settings),
}
