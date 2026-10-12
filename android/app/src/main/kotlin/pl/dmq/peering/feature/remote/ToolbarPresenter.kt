package pl.dmq.peering.feature.remote

/** Decides which buttons the bottom bar offers and what each one does. Agents and Files appear only when the computer supports them. */
class ToolbarPresenter {
    fun actions(capabilities: HubCapabilities): List<ToolbarAction> = buildList {
        add(ToolbarAction.KEYBOARD)
        add(ToolbarAction.SOURCES)
        if (capabilities.agentChat) add(ToolbarAction.AGENTS)
        if (capabilities.fileBrowser) add(ToolbarAction.FILES)
        add(ToolbarAction.MORE)
    }

    fun effect(action: ToolbarAction): ToolbarEffect = when (action) {
        ToolbarAction.KEYBOARD -> ToolbarEffect.ToggleKeyboard
        ToolbarAction.SOURCES -> ToolbarEffect.OpenSources
        ToolbarAction.AGENTS -> ToolbarEffect.OpenHub(HubEntry.AGENTS)
        ToolbarAction.FILES -> ToolbarEffect.OpenHub(HubEntry.FILES)
        ToolbarAction.MORE -> ToolbarEffect.OpenMore
    }

    fun otherMode(mode: InputMode): InputMode =
        if (mode == InputMode.TRACKPAD) InputMode.DIRECT else InputMode.TRACKPAD
}
