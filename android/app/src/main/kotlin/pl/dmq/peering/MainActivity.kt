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
        val preview = if (BuildConfig.DEBUG) intent.getStringExtra(PREVIEW_EXTRA) else null
        setContent {
            PeeringTheme { if (preview != null) DebugPreview(preview) else PeeringScaffold() }
        }
    }
}
