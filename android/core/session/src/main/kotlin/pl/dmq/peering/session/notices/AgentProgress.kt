package pl.dmq.peering.session.notices

import pl.dmq.peering.wire.AgentSessionState

/** What an agent turn in flight is doing, as the ongoing progress notification says it. */
enum class ProgressStage { WORKING, AWAITING_APPROVAL }

data class ProgressNotice(
    val chatID: String,
    val title: String,
    val stage: ProgressStage,
    val hostName: String?,
    val hostID: String?,
)

sealed interface ProgressAction {
    data class Show(val notice: ProgressNotice) : ProgressAction

    data class End(val chatID: String) : ProgressAction
}

/**
 * The Android stand-in for the Live Activity: one quiet ongoing notification per chat whose turn is running while the
 * app is out of sight. It changes only when the stage or title does, and ends when the turn does, where the finished
 * notice takes over. A chat still replaying history shows nothing, since its state is not yet the live one.
 */
class AgentProgress {
    private val shown = LinkedHashMap<String, ProgressNotice>()

    fun plan(inputs: NoticeInputs?): List<ProgressAction> {
        val wanted = if (inputs == null || !inputs.away || !inputs.enabled) {
            emptyMap()
        } else {
            inputs.chats.filter { it.loaded }.mapNotNull { chat -> notice(chat, inputs) }.associateBy { it.chatID }
        }
        val actions = mutableListOf<ProgressAction>()
        shown.keys.filterNot(wanted::containsKey).forEach { actions += ProgressAction.End(it) }
        wanted.values.filter { shown[it.chatID] != it }.forEach { actions += ProgressAction.Show(it) }
        shown.clear()
        shown.putAll(wanted)
        return actions
    }

    private fun notice(chat: ChatView, inputs: NoticeInputs): ProgressNotice? {
        val stage = when (chat.state) {
            AgentSessionState.WORKING -> ProgressStage.WORKING
            AgentSessionState.AWAITING_APPROVAL -> ProgressStage.AWAITING_APPROVAL
            else -> return null
        }
        return ProgressNotice(chat.chatID, chat.title, stage, inputs.hostName, inputs.hostID)
    }
}
