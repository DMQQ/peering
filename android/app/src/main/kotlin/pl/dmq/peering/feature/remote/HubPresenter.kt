package pl.dmq.peering.feature.remote

/** Decides what the terminal button offers for a computer: only what it declared it can do, the terminal first. */
class HubPresenter {
    fun terminalEntries(capabilities: HubCapabilities): List<HubEntry> = buildList {
        if (capabilities.terminal) add(HubEntry.TERMINAL)
        if (capabilities.agentChat) add(HubEntry.AGENTS)
        if (capabilities.fileBrowser) add(HubEntry.FILES)
    }
}
