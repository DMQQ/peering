package pl.dmq.peering

import android.Manifest
import android.graphics.Color
import android.content.Intent
import android.media.AudioManager
import android.os.Bundle
import android.widget.Toast
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
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
import pl.dmq.peering.background.NotificationExplanation
import pl.dmq.peering.ui.LockScreen
import pl.dmq.peering.ui.debug.DebugPreview
import pl.dmq.peering.ui.debug.PREVIEW_EXTRA
import pl.dmq.peering.ui.nav.PeeringScaffold
import pl.dmq.peering.ui.EndSessionPrompt
import pl.dmq.peering.ui.hasLiveSession
import pl.dmq.peering.ui.openFromWidget
import pl.dmq.peering.ui.theme.PeeringTheme
import pl.dmq.peering.ui.wiring.AppLock
import pl.dmq.peering.ui.wiring.DeviceUnlock
import pl.dmq.peering.ui.wiring.PreferencesFirstRunStore
import pl.dmq.peering.ui.wiring.ScreenSecurity
import pl.dmq.peering.widget.ExternalLinkGate
import pl.dmq.peering.widget.LinkNonce
import pl.dmq.peering.widget.LinkRequest
import pl.dmq.peering.widget.WidgetLink
import pl.dmq.peering.widget.WidgetLinkGate

/** A FragmentActivity because the system's unlock prompt is hosted by one. */
class MainActivity : FragmentActivity() {
    private lateinit var appLock: AppLock
    private var locked by mutableStateOf(false)
    private var connectRequests by mutableIntStateOf(0)
    private var sessionActive = false
    private val notificationPermission get() = (application as PeeringApplication).wiring?.background?.permission
    private val externalGate = ExternalLinkGate()
    private var confirmingLink by mutableStateOf<WidgetLink?>(null)
    private val linkGate by lazy { WidgetLinkGate(LinkNonce.load(noBackupFilesDir)) }

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        volumeControlStream = AudioManager.STREAM_MUSIC
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
        appLock = AppLock(preferences, (application as PeeringApplication).graph.preferenceWrites)
        val deviceLockAvailable = DeviceUnlock.isAvailable(this)
        if (ScreenSecurity.lockLapsed(appLock.isEnabled(), deviceLockAvailable)) {
            appLock.setEnabled(false)
            Toast.makeText(this, R.string.connect_lock_lapsed, Toast.LENGTH_LONG).show()
        }
        locked = appLock.isEnabled() && deviceLockAvailable
        announceUnreadablePairings()
        followSession()
        followNotificationPermission()
        val preview = if (BuildConfig.DEBUG) intent.getStringExtra(PREVIEW_EXTRA) else null
        if (savedInstanceState == null) openWidgetLink(intent)
        setContent {
            PeeringTheme {
                when {
                    preview != null -> DebugPreview(preview)
                    locked -> LockScreen(onUnlock = ::requestUnlock)
                    else -> PeeringScaffold(connectRequests)
                }
                if (!locked) notificationPermission?.let { NotificationExplanation(it) }
                confirmingLink?.let { EndSessionPrompt(onConfirm = ::confirmLink, onCancel = ::cancelLink) }
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

    /** The system dialog is launched from here because only an activity can; the app asks through the permission object. */
    private fun followNotificationPermission() {
        val permission = notificationPermission ?: return
        val launcher = registerForActivityResult(ActivityResultContracts.RequestPermission(), permission::onSystemDialogAnswered)
        permission.launchSystemDialog = { launcher.launch(Manifest.permission.POST_NOTIFICATIONS) }
    }

    private fun announceUnreadablePairings() {
        val graph = (application as PeeringApplication).graph
        lifecycleScope.launch {
            if (withContext(Dispatchers.Default) { graph.takePairingsUnreadable() }) {
                Toast.makeText(this@MainActivity, R.string.connect_pairings_unreadable, Toast.LENGTH_LONG).show()
            }
        }
    }

    override fun onDestroy() {
        notificationPermission?.launchSystemDialog = null
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openWidgetLink(intent)
    }

    private fun openWidgetLink(intent: Intent) {
        val request = LinkRequest(intent.dataString.orEmpty(), intent.getStringExtra(LinkNonce.EXTRA))
        if (LinkNonce.accepts(linkGate.expectedNonce, request.nonce)) {
            act(linkGate.receive(request, locked) ?: return)
        } else {
            openOutsideLink(request.data)
        }
    }

    /** A link from a page or another app carries no nonce: it is run under the outside-link rules. */
    private fun openOutsideLink(data: String) {
        val link = WidgetLink.parse(data) ?: return
        externalGate.setLocked(locked)?.let(::submitOutsideLink)
        submitOutsideLink(link)
    }

    private fun submitOutsideLink(link: WidgetLink) {
        val wiring = (application as PeeringApplication).wiring ?: return
        externalGate.submit(link, wiring.hasLiveSession())?.let(::act)
        confirmingLink = externalGate.confirming
    }

    private fun confirmLink() {
        externalGate.confirm()?.let(::act)
        confirmingLink = null
    }

    private fun cancelLink() {
        externalGate.cancelConfirmation()
        confirmingLink = null
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
        if (!hubOnTop && appLock.isEnabled() && DeviceUnlock.isAvailable(this)) {
            locked = true
            externalGate.setLocked(true)
            confirmingLink = null
        }
    }

    private fun requestUnlock() {
        DeviceUnlock.prompt(this, getString(R.string.connect_unlock_title)) { unlocked ->
            if (unlocked) {
                locked = false
                linkGate.released()?.let(::act)
                externalGate.setLocked(false)?.let(::submitOutsideLink)
            }
        }
    }

    companion object {
        /** Debug builds only: `--ez reset_first_run true` shows the first run again. */
        const val RESET_FIRST_RUN_EXTRA = "reset_first_run"
        const val PREFERENCES_NAME = "peering"
    }
}
