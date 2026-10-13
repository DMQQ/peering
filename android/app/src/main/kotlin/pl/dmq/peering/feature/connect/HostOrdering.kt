package pl.dmq.peering.feature.connect

internal object HostOrdering {
    private val byStatusThenName = compareBy<HostRow>(
        { it.status },
        { it.name == null },
        { it.name?.lowercase().orEmpty() },
        { it.id },
    )

    fun order(rows: List<HostRow>): List<HostRow> = rows.sortedWith(byStatusThenName)
}
