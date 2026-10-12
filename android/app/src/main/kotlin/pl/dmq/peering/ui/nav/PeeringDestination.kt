package pl.dmq.peering.ui.nav

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Settings
import androidx.compose.ui.graphics.vector.ImageVector
import pl.dmq.peering.R

enum class PeeringDestination(
    val route: String,
    @StringRes val labelRes: Int,
    val icon: ImageVector,
) {
    Connect("connect", R.string.nav_connect, Icons.Filled.Phone),
    Sessions("sessions", R.string.nav_sessions, Icons.AutoMirrored.Filled.List),
    Settings("settings", R.string.nav_settings, Icons.Filled.Settings),
}
