package pl.dmq.peering.ui.nav

import androidx.annotation.StringRes
import androidx.compose.ui.graphics.vector.ImageVector
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.Symbols

/** The tabs, in the order the iPhone's bar shows them (it also has Servers, which this app has no SSH client for). */
enum class PeeringDestination(
    val route: String,
    @StringRes val labelRes: Int,
    val icon: ImageVector,
) {
    Connect("connect", R.string.nav_connect, Symbols.macbookAndIphone),
    Sessions("sessions", R.string.nav_sessions, Symbols.clock),
    Faq("faq", R.string.nav_faq, Symbols.questionmarkCircle),
    Settings("settings", R.string.nav_settings, Symbols.gearshape),
}
