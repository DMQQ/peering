package pl.dmq.peering.feature.remote

enum class ToolbarAction { KEYBOARD, SOURCES, AGENTS, FILES, MORE }

/** What the screen does when a bar button is tapped. */
sealed class ToolbarEffect {
    data object ToggleKeyboard : ToolbarEffect()

    data object OpenSources : ToolbarEffect()

    data object OpenMore : ToolbarEffect()

    /** Handled by the session, which opens the agent or file screen. */
    data class OpenHub(val entry: HubEntry) : ToolbarEffect()
}
