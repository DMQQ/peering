package pl.dmq.peering

import android.app.Application
import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.files.GalleryStore
import pl.dmq.peering.platform.PlatformLog
import pl.dmq.peering.ui.FeatureWiring
import pl.dmq.peering.ui.wiring.HubDependencies

class PeeringApplication : Application() {
    val graph: AppGraph by lazy { AppGraph(this) }

    /** What the hub's activity reads; null until [onCreate] has built the wiring. */
    internal var hubDependencies: HubDependencies? = null
        private set

    /** The wiring the screens share; null until [onCreate] has built it. */
    internal var wiring: FeatureWiring? = null
        private set

    /** Work that outlives any one screen, such as a save to the gallery the phone was turned during. */
    internal lateinit var scope: CoroutineScope
        private set

    /** Whether the hub is on top of the main activity, which then stays unlocked when it stops. */
    internal var hubOpen = false

    override fun onCreate() {
        super.onCreate()
        PlatformLog.enabled = BuildConfig.DEBUG
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate + survivableErrorHandler())
        this.scope = scope
        scope.launch(Dispatchers.IO) { deleteStaleGalleryItems() }
        val preferences = getSharedPreferences(MainActivity.PREFERENCES_NAME, Context.MODE_PRIVATE)
        val wiring = FeatureWiring(graph, scope, preferences)
        this.wiring = wiring
        wiring.install()
        hubDependencies = HubDependencies(wiring.holder.active, wiring.drafts, wiring.folderRecents, wiring.clock)
    }

    private fun deleteStaleGalleryItems() {
        try {
            GalleryStore.deleteStalePending(contentResolver, packageName)
        } catch (failure: Exception) {
            DebugLog.w(TAG, { "deleting stale gallery items failed" }, failure)
        }
    }
}

/** The application the screens run in. */
internal val Context.peeringApplication: PeeringApplication get() = applicationContext as PeeringApplication

private const val TAG = "PeeringApplication"
