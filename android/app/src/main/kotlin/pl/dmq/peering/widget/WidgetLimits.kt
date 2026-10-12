package pl.dmq.peering.widget

/** What the widget snapshots may hold, so a host with thousands of chats or very long names cannot grow the preferences file without bound. */
internal object WidgetLimits {
    const val MAX_CHATS = 30
    const val MAX_COMPUTERS = 50
    const val MAX_TEXT = 120

    fun text(value: String): String = value.take(MAX_TEXT)

    fun bounded(snapshot: QuickConnectSnapshot): QuickConnectSnapshot {
        val computers = snapshot.computers.take(MAX_COMPUTERS).map { it.copy(name = text(it.name)) }
        val ids = computers.mapTo(mutableSetOf()) { it.id }
        return snapshot.copy(
            computers = computers,
            connectedId = snapshot.connectedId?.takeIf { it in ids },
            onlineIds = snapshot.onlineIds.filterTo(mutableSetOf()) { it in ids },
        )
    }
}
