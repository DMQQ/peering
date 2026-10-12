package pl.dmq.peering.ui.nav

import android.graphics.Color
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import pl.dmq.peering.MainActivity
import pl.dmq.peering.PeeringApplication
import pl.dmq.peering.R
import pl.dmq.peering.ui.LockScreen
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringTheme
import pl.dmq.peering.ui.wiring.AppLock
import pl.dmq.peering.ui.wiring.DeviceUnlock
import pl.dmq.peering.ui.wiring.hubShouldClose

/**
 * Agents, Terminals and Files in their own activity, so the system's own open, close and back-gesture animations apply.
 * It reads the live session from the application and closes when there is none or the session ends.
 */
class HubActivity : FragmentActivity() {
    private var appLock: AppLock? = null
    private var locked by mutableStateOf(false)

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as PeeringApplication
        val dependencies = app.hubDependencies
        val session = dependencies?.active?.value
        if (dependencies == null || session == null) {
            finish()
            return
        }
        app.hubOpen = true
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        window.isNavigationBarContrastEnforced = false
        appLock = AppLock(getSharedPreferences(MainActivity.PREFERENCES_NAME, MODE_PRIVATE))
        lifecycleScope.launch {
            dependencies.active
                .flatMapLatest { current ->
                    if (current == null) flowOf(null to null) else current.controller.state.map { current to it.phase }
                }
                .collect { (current, phase) ->
                    if (hubShouldClose(isOpenedSession = current === session, phase = phase)) finish()
                }
        }
        setContent {
            PeeringTheme {
                Box(Modifier.fillMaxSize().background(PeeringColors.backdrop)) {
                    if (locked) {
                        LockScreen(onUnlock = ::requestUnlock)
                    } else {
                        SessionHub(session, dependencies.drafts, dependencies.folderRecents, dependencies.clock, onClose = ::finish)
                    }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (locked) requestUnlock()
    }

    // MainActivity does not lock while this is open, so leaving the app from here has to.
    override fun onStop() {
        super.onStop()
        val lock = appLock ?: return
        if (!isFinishing && !isChangingConfigurations && lock.isEnabled() && DeviceUnlock.isAvailable(this)) locked = true
    }

    override fun onDestroy() {
        super.onDestroy()
        (application as PeeringApplication).hubOpen = false
    }

    private fun requestUnlock() {
        DeviceUnlock.prompt(this, getString(R.string.connect_unlock_title)) { unlocked -> if (unlocked) locked = false }
    }
}
