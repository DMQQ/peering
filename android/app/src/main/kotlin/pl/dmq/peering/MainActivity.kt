package pl.dmq.peering

import android.graphics.Color
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import pl.dmq.peering.ui.LockScreen
import pl.dmq.peering.ui.debug.DebugPreview
import pl.dmq.peering.ui.debug.PREVIEW_EXTRA
import pl.dmq.peering.ui.nav.PeeringScaffold
import pl.dmq.peering.ui.openFromWidget
import pl.dmq.peering.ui.theme.PeeringTheme
import pl.dmq.peering.ui.wiring.AppLock
import pl.dmq.peering.ui.wiring.DeviceUnlock
import pl.dmq.peering.ui.wiring.PreferencesFirstRunStore
import pl.dmq.peering.ui.wiring.ScreenSecurity
import pl.dmq.peering.widget.LockedLinkQueue
import pl.dmq.peering.widget.WidgetLink

/** A FragmentActivity because the system's unlock prompt is hosted by one. */
class MainActivity : FragmentActivity() {
    private lateinit var appLock: AppLock
    private var locked by mutableStateOf(false)
    private var connectRequests by mutableIntStateOf(0)
    private var sessionActive = false
    private val lockedLinks = LockedLinkQueue()

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        // Three-button navigation otherwise gets a scrim that tints the bottom bar a different black.
        window.isNavigationBarContrastEnforced = false
        val preferences = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
        if (BuildConfig.DEBUG && intent.getBooleanExtra(RESET_FIRST_RUN_EXTRA, false)) {
            PreferencesFirstRunStore(preferences).reset()
        }
        appLock = AppLock(preferences)
        val deviceLockAvailable = DeviceUnlock.isAvailable(this)
        if (ScreenSecurity.lockLapsed(appLock.isEnabled(), deviceLockAvailable)) {
            appLock.setEnabled(false)
            Toast.makeText(this, R.string.connect_lock_lapsed, Toast.LENGTH_LONG).show()
        }
        locked = appLock.isEnabled() && deviceLockAvailable
        announceUnreadablePairings()
        followSession()
        val preview = if (BuildConfig.DEBUG) intent.getStringExtra(PREVIEW_EXTRA) else null
        if (savedInstanceState == null) openWidgetLink(intent)
        setContent {
            PeeringTheme {
                when {
                    preview != null -> DebugPreview(preview)
                    locked -> LockScreen(onUnlock = ::requestUnlock)
                    else -> PeeringScaffold(connectRequests)
                }
            }
        }
    }

    /** Applies FLAG_SECURE for the lock and for a live session, which would otherwise show in recents and screenshots. */
    internal fun refreshScreenSecurity() {
        ScreenSecurity.apply(window, ScreenSecurity.hidesContent(appLock.isEnabled(), locked, sessionOnScreen = sessionActive))
    }

    private fun followSession() {
        val holder = checkNotNull((application as PeeringApplication).wiring) {
            "PeeringApplication.onCreate builds the wiring before any activity starts"
        }.holder
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                holder.active.collect {
                    sessionActive = it != null
                    refreshScreenSecurity()
                }
            }
        }
    }

    private fun announceUnreadablePairings() {
        val graph = (application as PeeringApplication).graph
        lifecycleScope.launch {
            if (withContext(Dispatchers.Default) { graph.takePairingsUnreadable() }) {
                Toast.makeText(this@MainActivity, R.string.connect_pairings_unreadable, Toast.LENGTH_LONG).show()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openWidgetLink(intent)
    }

    private fun openWidgetLink(intent: Intent) {
        val link = WidgetLink.parse(intent.dataString) ?: return
        act(lockedLinks.admit(link, locked) ?: return)
    }

    private fun act(link: WidgetLink) {
        (application as PeeringApplication).wiring?.openFromWidget(link)
        connectRequests++
    }

    override fun onStart() {
        super.onStart()
        refreshScreenSecurity()
        if (locked) requestUnlock()
    }

    override fun onStop() {
        super.onStop()
        val hubOnTop = (application as PeeringApplication).hubOpen
        if (!hubOnTop && appLock.isEnabled() && DeviceUnlock.isAvailable(this)) locked = true
    }

    private fun requestUnlock() {
        DeviceUnlock.prompt(this, getString(R.string.connect_unlock_title)) { unlocked ->
            if (unlocked) {
                locked = false
                lockedLinks.release()?.let(::act)
            }
        }
    }

    companion object {
        /** Debug builds only: `--ez reset_first_run true` shows the first run again. */
        const val RESET_FIRST_RUN_EXTRA = "reset_first_run"
        const val PREFERENCES_NAME = "peering"
    }
}
