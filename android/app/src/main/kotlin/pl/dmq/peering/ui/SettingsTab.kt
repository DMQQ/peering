package pl.dmq.peering.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import pl.dmq.peering.feature.settings.SettingsPresenter
import pl.dmq.peering.feature.settings.SettingsRoute
import pl.dmq.peering.ui.wiring.IdentityResetNotOffered

/** The Settings tab. Legal pages are not bundled yet, so opening one does nothing for now. */
@Composable
internal fun SettingsTab(wiring: FeatureWiring) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val presenter = remember(wiring, scope) {
        SettingsPresenter(
            trusted = wiring.trusted,
            identity = IdentityResetNotOffered,
            preferences = wiring.settings,
            appVersion = context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty(),
            scope = scope,
        )
    }
    SettingsRoute(presenter = presenter, onOpenLegal = {})
}
