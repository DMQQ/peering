package pl.dmq.peering.feature.remote

/** What the connected Mac declared it can do, as far as the hub needs to know. */
data class HubCapabilities(val agentChat: Boolean, val fileBrowser: Boolean, val terminal: Boolean = false) {
    companion object {
        val NONE = HubCapabilities(agentChat = false, fileBrowser = false)
    }
}
