package pl.dmq.peering.session.agent.changes

import pl.dmq.peering.wire.AgentChangedFile

/** Which changed files a commit takes. Every file starts chosen; a tap takes it out and a second tap puts it back. */
data class CommitSelection(private val unticked: Set<String> = emptySet()) {
    fun isChosen(file: AgentChangedFile): Boolean = file.path !in unticked

    fun toggle(file: AgentChangedFile): CommitSelection =
        CommitSelection(if (file.path in unticked) unticked - file.path else unticked + file.path)

    /** The files to commit, in the report's order. */
    fun chosen(files: List<AgentChangedFile>): List<AgentChangedFile> = files.filter(::isChosen)
}
