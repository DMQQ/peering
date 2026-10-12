package pl.dmq.peering.feature.remote

/** Decides which entries the session hub offers for a Mac. Sources, Quality and Disconnect are always there. */
class HubPresenter {
    fun entries(capabilities: HubCapabilities): List<HubEntry> = buildList {
        add(HubEntry.SOURCES)
        if (capabilities.agentChat) add(HubEntry.AGENTS)
        if (capabilities.fileBrowser) add(HubEntry.FILES)
        if (capabilities.terminal) add(HubEntry.TERMINAL)
        add(HubEntry.QUALITY)
        add(HubEntry.DISCONNECT)
    }
}
