package pl.dmq.peering

import android.app.Application
import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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

    /** Whether the hub is on top of the main activity, which then stays unlocked when it stops. */
    internal var hubOpen = false

    override fun onCreate() {
        super.onCreate()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate + survivableErrorHandler())
        val preferences = getSharedPreferences(MainActivity.PREFERENCES_NAME, Context.MODE_PRIVATE)
        val wiring = FeatureWiring(graph, scope, preferences)
        this.wiring = wiring
        wiring.install()
        hubDependencies = HubDependencies(wiring.holder.active, wiring.drafts, wiring.folderRecents, wiring.clock)
    }
}
