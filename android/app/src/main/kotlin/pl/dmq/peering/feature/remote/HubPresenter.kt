package pl.dmq.peering.feature.remote

/** Decides which tabs the hub panel offers for a computer: only what it declared it can do. */
class HubPresenter {
    fun offeredTabs(capabilities: HubCapabilities): List<HubTab> = buildList {
        if (capabilities.agentChat) add(HubTab.AGENTS)
        if (capabilities.terminal) add(HubTab.TERMINALS)
        if (capabilities.fileBrowser) add(HubTab.FILES)
    }
}
