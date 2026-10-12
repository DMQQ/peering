package pl.dmq.peering

import android.app.Application

class PeeringApplication : Application() {
    val graph: AppGraph by lazy { AppGraph(this) }
}
