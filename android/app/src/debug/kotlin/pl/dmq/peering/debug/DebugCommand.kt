package pl.dmq.peering.debug

/** What a broadcast asks for: an action name the screens register, and its argument. */
sealed interface DebugCommand {
    data class Run(val action: String, val argument: String?) : DebugCommand

    data object Dump : DebugCommand

    data class Invalid(val reason: String) : DebugCommand

    companion object {
        private val tabs = setOf("connect", "sessions", "faq", "settings")
        private val hubs = setOf("agents", "terminals", "files", "close")
        private val panels = setOf("apps", "keyboard", "clipboard", "shortcuts", "settings", "close")
        private val hostId = Regex("[A-Za-z0-9_.:-]{1,128}")
        private const val MAX_TEXT = 500
        private const val MAX_PAGE = 99

        /** Only commands that look and report. Nothing here types, clicks, starts a shell or an agent, or deletes. */
        fun parse(command: String?, argument: String?): DebugCommand {
            val arg = argument?.trim()?.takeIf { it.isNotEmpty() }
            val name = command?.trim()
            return when (name) {
                "dump" -> Dump
                "back", "disconnect", "terminal-list", "clipboard-history" -> Run(name, null)
                "tab" -> oneOf("tab", arg, tabs)
                "hub" -> oneOf("hub", arg, hubs)
                "panel" -> oneOf("panel", arg, panels)
                "pill" -> oneOf("pill", arg, setOf("open", "close"))
                "mosaic" -> oneOf("mosaic", arg, setOf("start", "stop"))
                "onboarding" -> oneOf("onboarding", arg, setOf("reset", "skip"))
                "dock" -> dock(arg)
                "connect" -> if (arg != null && hostId.matches(arg)) Run("connect", arg) else Invalid("connect needs trusted or a host id")
                "files-open" -> Run("files-open", arg ?: "~")
                "files-preview" -> if (arg != null) Run("files-preview", arg) else Invalid("files-preview needs a path")
                "clipboard-send" -> when {
                    arg == null -> Invalid("clipboard-send needs text")
                    arg.length > MAX_TEXT -> Invalid("clipboard-send text is over $MAX_TEXT characters")
                    else -> Run("clipboard-send", arg)
                }
                null, "" -> Invalid("no cmd")
                else -> Invalid("unknown cmd $name")
            }
        }

        private fun oneOf(action: String, arg: String?, allowed: Set<String>): DebugCommand =
            if (arg in allowed) Run(action, arg) else Invalid("$action takes one of ${allowed.joinToString("|")}")

        private fun dock(arg: String?): DebugCommand {
            if (arg == "expand" || arg == "collapse") return Run("dock", arg)
            val page = arg?.removePrefix("page")?.trim(' ', ':')?.toIntOrNull()
            return if (arg != null && arg.startsWith("page") && page != null && page in 0..MAX_PAGE) {
                Run("dock-page", page.toString())
            } else {
                Invalid("dock takes expand|collapse|page N")
            }
        }
    }
}
