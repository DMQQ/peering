package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.Modifiers

/** A shortcut worth offering for one application. [detail] says why to press it, which is what is spoken. */
data class ApplicationAction(
    val id: String,
    val title: String,
    val detail: String,
    val label: String,
    val keyCode: Int,
    val modifiers: Long,
)

data class ApplicationProfile(val bundleId: String, val name: String, val actions: List<ApplicationAction>)

/** The applications the app has something particular to say about, keyed by bundle identifier. */
object ApplicationProfiles {
    /** Null when there is nothing special to offer. */
    fun forBundle(bundleId: String?): ApplicationProfile? = bundleId?.let(table::get)

    private const val CMD = Modifiers.COMMAND
    private const val CTRL = Modifiers.CONTROL
    private const val SHIFT = Modifiers.SHIFT
    private const val OPT = Modifiers.OPTION

    private fun action(id: String, title: String, detail: String, label: String, keyCode: Int, modifiers: Long) =
        ApplicationAction(id, title, detail, label, keyCode, modifiers)

    private fun shell(prefix: String, withKillLine: Boolean): List<ApplicationAction> = listOfNotNull(
        action("$prefix.interrupt", "⌃C", "Interrupt what is running", "Stop", 8, CTRL),
        action("$prefix.eof", "⌃D", "End input, or close the shell", "EOF", 2, CTRL),
        action("$prefix.clear", "⌃L", "Clear the screen", "Clear", 37, CTRL),
        action("$prefix.history", "⌃R", "Search command history", "History", 15, CTRL),
        action("$prefix.start", "⌃A", "Jump to the start of the line", "Start", 0, CTRL),
        action("$prefix.end", "⌃E", "Jump to the end of the line", "End", 14, CTRL),
        if (withKillLine) action("$prefix.killline", "⌃U", "Delete back to the start", "Kill line", 32, CTRL) else null,
        action("$prefix.deleteword", "⌃W", "Delete the word behind", "Del word", 13, CTRL),
    )

    private val terminalLike = shell("terminal", withKillLine = true) + listOf(
        action("terminal.clearbuffer", "⌘K", "Clear the scrollback", "Scrollback", 40, CMD),
        action("terminal.newtab", "⌘T", "New tab", "New tab", 17, CMD),
    )

    private val ghostty = terminalLike.map { it.copy(id = it.id.replace("terminal.", "ghostty.")) }

    private val iterm = shell("iterm", withKillLine = false) +
        action("iterm.split", "⌘D", "Split the pane", "Split", 2, CMD)

    private val profiles = listOf(
        ApplicationProfile("com.apple.Terminal", "Terminal", terminalLike),
        ApplicationProfile("com.mitchellh.ghostty", "Ghostty", ghostty),
        ApplicationProfile("com.googlecode.iterm2", "iTerm", iterm),
        ApplicationProfile(
            "com.apple.dt.Xcode",
            "Xcode",
            listOf(
                action("xcode.build", "⌘B", "Build", "Build", 11, CMD),
                action("xcode.run", "⌘R", "Run", "Run", 15, CMD),
                action("xcode.stop", "⌘.", "Stop", "Stop", 47, CMD),
                action("xcode.openquickly", "⌘⇧O", "Open quickly", "Open", 31, CMD or SHIFT),
                action("xcode.clean", "⌘⇧K", "Clean the build folder", "Clean", 40, CMD or SHIFT),
                action("xcode.issues", "⌘⇧M", "Show the issue navigator", "Issues", 46, CMD or SHIFT),
            ),
        ),
        ApplicationProfile(
            "com.microsoft.VSCode",
            "Visual Studio Code",
            listOf(
                action("vscode.commands", "⌘⇧P", "Command palette", "Commands", 35, CMD or SHIFT),
                action("vscode.quickopen", "⌘P", "Go to file", "Go to file", 35, CMD),
                action("vscode.terminal", "⌃`", "Toggle the terminal", "Terminal", 50, CTRL),
                action("vscode.sidebar", "⌘B", "Toggle the sidebar", "Sidebar", 11, CMD),
                action("vscode.saveall", "⌘⌥S", "Save all", "Save all", 1, CMD or OPT),
            ),
        ),
        ApplicationProfile(
            "com.apple.Safari",
            "Safari",
            listOf(
                action("safari.newtab", "⌘T", "New tab", "New tab", 17, CMD),
                action("safari.location", "⌘L", "Go to the address field", "Address", 37, CMD),
                action("safari.reload", "⌘R", "Reload", "Reload", 15, CMD),
                action("safari.back", "⌘[", "Back", "Back", 33, CMD),
                action("safari.forward", "⌘]", "Forward", "Forward", 30, CMD),
                action("safari.reader", "⌘⇧R", "Reader view", "Reader", 15, CMD or SHIFT),
            ),
        ),
        ApplicationProfile(
            "com.apple.finder",
            "Finder",
            listOf(
                action("finder.goto", "⌘⇧G", "Go to a folder by path", "Go to", 5, CMD or SHIFT),
                action("finder.newfolder", "⌘⇧N", "New folder", "Folder", 45, CMD or SHIFT),
                action("finder.trash", "⌘⌫", "Move to the bin", "Bin", 51, CMD),
                action("finder.hidden", "⌘⇧.", "Show hidden files", "Hidden", 47, CMD or SHIFT),
                action("finder.parent", "⌘↑", "Enclosing folder", "Up", 126, CMD),
            ),
        ),
    )

    private val table: Map<String, ApplicationProfile> = profiles.associateBy { it.bundleId }
}
