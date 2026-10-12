package pl.dmq.peering.ui.nav

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import pl.dmq.peering.R

@Composable
internal fun ConnectPlaceholder() = PlaceholderScreen(R.string.nav_connect)

@Composable
internal fun SessionsPlaceholder() = PlaceholderScreen(R.string.nav_sessions)

@Composable
internal fun SettingsPlaceholder() = PlaceholderScreen(R.string.nav_settings)

@Composable
private fun PlaceholderScreen(labelRes: Int) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(stringResource(labelRes))
    }
}
