package pl.dmq.peering.feature.agents.review

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.feature.agents.AgentsPort
import pl.dmq.peering.session.agent.AgentChatState
import pl.dmq.peering.session.agent.changes.AgentChangesByChat
import pl.dmq.peering.session.agent.changes.ReviewGroup
import pl.dmq.peering.session.agent.changes.ReviewMarkStore
import pl.dmq.peering.session.agent.changes.ReviewMarks
import pl.dmq.peering.session.agent.changes.ReviewQueue
import pl.dmq.peering.session.agent.changes.ReviewRefreshPolicy
import pl.dmq.peering.session.agent.changes.ReviewSource
import pl.dmq.peering.wire.AgentChangedFile
import pl.dmq.peering.wire.AgentSessionState

/**
 * The cross-chat list of changed files that still await a look. It remembers which files were marked reviewed, drops a
 * mark when its file changes again, and asks the computer for each chat's changes when the hub appears or a turn ends.
 */
class ReviewInbox(
    private val port: AgentsPort,
    private val store: ReviewMarkStore,
    scope: CoroutineScope,
    private val nowMillis: () -> Long,
) {
    private val marks = MutableStateFlow(store.load())
    private val policy = ReviewRefreshPolicy()
    private var lastStates: Map<String, AgentSessionState> = emptyMap()

    init {
        scope.launch { port.chats.collect(::onChatsChanged) }
        scope.launch { port.changes.collect(::absorb) }
    }

    val queue: StateFlow<ReviewQueue> = combine(port.chats, port.changes, marks) { chats, changes, held -> build(chats, changes, held) }
        .stateIn(scope, SharingStarted.Eagerly, build(port.chats.value, port.changes.value, marks.value))

    fun setReviewed(chatId: String, file: AgentChangedFile, reviewed: Boolean) = save(marks.value.withReviewed(reviewed, file, chatId))

    /** Marks every file of the chat that is shown, or takes the marks off when they all are already. */
    fun toggleAll(group: ReviewGroup) {
        val reviewAll = group.pending.isNotEmpty()
        save(group.files.fold(marks.value) { held, entry -> held.withReviewed(reviewAll, entry.file, group.chatId) })
    }

    /** The hub came on screen: chats not asked about lately are asked now. */
    fun onHubAppeared() = ask(ReviewRefreshPolicy.Reason.HUB_APPEARED, port.chats.value.sessions.map { it.id })

    /**
     * Asks about chats whose turn just ended, and forgets what belongs to chats that are gone. An empty list is a chat
     * list not received yet, not a reason to forget every mark.
     */
    internal fun onChatsChanged(chats: AgentChatState) {
        val states = chats.sessions.associate { it.id to it.state }
        val finished = states.filter { (id, state) ->
            state == AgentSessionState.IDLE && lastStates[id].let { it == AgentSessionState.WORKING || it == AgentSessionState.AWAITING_APPROVAL }
        }.keys.toList()
        lastStates = states
        if (finished.isNotEmpty()) ask(ReviewRefreshPolicy.Reason.TURN_FINISHED, finished)
        policy.forgetExcept(states.keys)
        if (states.isNotEmpty()) marks.update { it.retaining(states.keys) }
    }

    /** Takes in a chat's answer: a real one outdates marks of files that moved on. */
    internal fun absorb(changes: AgentChangesByChat) {
        var held = marks.value
        for ((chat, state) in changes) state.report?.let { held = held.pruned(chat, it) }
        if (held != marks.value) save(held)
    }

    private fun ask(reason: ReviewRefreshPolicy.Reason, chats: List<String>) {
        policy.chatsToAsk(chats, reason, nowMillis()).forEach(port::loadChanges)
    }

    private fun save(next: ReviewMarks) {
        marks.value = next
        store.save(next)
    }

    private fun build(chats: AgentChatState, changes: AgentChangesByChat, held: ReviewMarks): ReviewQueue =
        ReviewQueue.of(
            chats.sessions.map { session ->
                val state = changes[session.id]
                ReviewSource(session.id, session.title, session.info.directory, state?.report, state?.loading == true)
            },
            held,
        )
}
