package pl.dmq.peering.ui.nav

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.ui.graphics.vector.ImageVector
import pl.dmq.peering.R

/** The root tabs, in the order the iPhone's tabs show them (it also has Servers, which this app has no SSH client for). */
enum class PeeringDestination(
    val route: String,
    @StringRes val labelRes: Int,
    val icon: ImageVector,
    val selectedIcon: ImageVector,
) {
    Connect("connect", R.string.nav_connect, Icons.Outlined.Devices, Icons.Filled.Devices),
    Sessions("sessions", R.string.nav_sessions, Icons.Outlined.History, Icons.Filled.History),
    Faq("faq", R.string.nav_faq, Icons.AutoMirrored.Outlined.HelpOutline, Icons.AutoMirrored.Filled.HelpOutline),
    Settings("settings", R.string.nav_settings, Icons.Outlined.Settings, Icons.Filled.Settings),
}
