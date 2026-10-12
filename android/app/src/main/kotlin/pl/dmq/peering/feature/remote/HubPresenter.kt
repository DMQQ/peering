package pl.dmq.peering.feature.remote

/** Decides which entries the session hub offers for a Mac. Sources, Quality and Disconnect are always there. */
class HubPresenter {
    fun entries(capabilities: HubCapabilities): List<HubEntry> = buildList {
        add(HubEntry.SOURCES)
        if (capabilities.agentChat) add(HubEntry.AGENTS)
        if (capabilities.fileBrowser) add(HubEntry.FILES)
        add(HubEntry.QUALITY)
        add(HubEntry.DISCONNECT)
    }

    /** What the More sheet lists beyond the bar's own buttons. */
    fun moreEntries(): List<HubEntry> = listOf(HubEntry.QUALITY, HubEntry.DISCONNECT)
}
