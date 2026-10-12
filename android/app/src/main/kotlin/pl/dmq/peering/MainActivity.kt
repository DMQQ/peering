package pl.dmq.peering

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import pl.dmq.peering.ui.debug.DebugPreview
import pl.dmq.peering.ui.debug.PREVIEW_EXTRA
import pl.dmq.peering.ui.nav.PeeringScaffold
import pl.dmq.peering.ui.theme.PeeringTheme
import pl.dmq.peering.ui.wiring.PreferencesFirstRunStore

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        // Three-button navigation otherwise gets a scrim that tints the bottom bar a different black.
        window.isNavigationBarContrastEnforced = false
        if (BuildConfig.DEBUG && intent.getBooleanExtra(RESET_FIRST_RUN_EXTRA, false)) {
            PreferencesFirstRunStore(getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)).reset()
        }
        val preview = if (BuildConfig.DEBUG) intent.getStringExtra(PREVIEW_EXTRA) else null
        setContent {
            PeeringTheme { if (preview != null) DebugPreview(preview) else PeeringScaffold() }
        }
    }

    companion object {
        /** Debug builds only: `--ez reset_first_run true` shows the first run again. */
        const val RESET_FIRST_RUN_EXTRA = "reset_first_run"
        const val PREFERENCES_NAME = "peering"
    }
}
