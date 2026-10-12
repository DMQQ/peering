package pl.dmq.peering

import android.app.Application
import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import pl.dmq.peering.ui.FeatureWiring

class PeeringApplication : Application() {
    val graph: AppGraph by lazy { AppGraph(this) }

    override fun onCreate() {
        super.onCreate()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val preferences = getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        FeatureWiring(graph, scope, preferences).install()
    }

    private companion object {
        const val PREFERENCES_NAME = "peering"
    }
}
