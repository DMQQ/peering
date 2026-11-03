package pl.dmq.peering.feature.sessionmode

/** How a connected computer is used: its picture, the hub of agents, files and terminals, or a dock that sends input with no picture. */
enum class SessionMode(val key: String) {
    SCREEN("screen"),
    WORKSPACE("workspace"),
    REMOTE("remote"),
    ;

    /** Only the screen needs the computer to send its picture. */
    val needsPicture: Boolean get() = this == SCREEN

    companion object {
        fun fromKey(key: String?): SessionMode? = entries.firstOrNull { it.key == key }

        /** The workspace is offered only when the computer has an agent chat, a file browser or a terminal to show. */
        fun available(workspaceOffered: Boolean): List<SessionMode> =
            entries.filter { it != WORKSPACE || workspaceOffered }
    }
}
