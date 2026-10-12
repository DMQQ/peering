package pl.dmq.peering.feature.agents

class InMemoryFolderRecentsStore(initial: Map<String, List<String>> = emptyMap()) : FolderRecentsStore {
    val saved = initial.toMutableMap()

    override fun load(hostID: String): List<String> = saved[hostID].orEmpty()

    override fun save(hostID: String, paths: List<String>) {
        saved[hostID] = paths
    }
}
