package pl.dmq.peering.widget

import android.content.Context

/** The snapshots the app writes and the widgets read, in their own preferences file so a widget never opens the app's. */
class WidgetStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun quickConnect(): QuickConnectSnapshot = WidgetCodec.decodeQuickConnect(preferences.getString(QUICK_CONNECT, null))

    fun agents(): AgentsSnapshot = WidgetCodec.decodeAgents(preferences.getString(AGENTS, null))

    fun write(snapshot: QuickConnectSnapshot) {
        preferences.edit().putString(QUICK_CONNECT, WidgetCodec.encode(snapshot)).apply()
    }

    fun write(snapshot: AgentsSnapshot) {
        preferences.edit().putString(AGENTS, WidgetCodec.encode(snapshot)).apply()
    }

    private companion object {
        const val FILE = "peering_widgets"
        const val QUICK_CONNECT = "quick_connect"
        const val AGENTS = "agents"
    }
}
