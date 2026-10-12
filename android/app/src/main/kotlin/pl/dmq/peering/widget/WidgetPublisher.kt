package pl.dmq.peering.widget

import android.content.Context
import pl.dmq.peering.DebugLog
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import androidx.glance.appwidget.updateAll
import pl.dmq.peering.feature.settings.TrustedHost
import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.ui.wiring.ActiveSession

/**
 * Writes what the widgets show and tells them to redraw. Throttled to one write a second: a streaming reply changes the
 * transcript many times a second, and a widget update is not free.
 */
class WidgetPublisher internal constructor(
    context: Context,
    private val scope: CoroutineScope,
    private val clock: Clock,
) {
    private val appContext = context.applicationContext
    private val store = WidgetStore(appContext)
    private val book = AgentSnapshotBook()

    @OptIn(ExperimentalCoroutinesApi::class)
    internal fun start(
        trusted: Flow<List<TrustedHost>>,
        connectedHostId: Flow<String?>,
        onlineHostIds: Flow<Set<String>>,
        active: Flow<ActiveSession?>,
    ) {
        clearConnected()
        scope.launch {
            combine(trusted, connectedHostId, onlineHostIds) { hosts, connected, online ->
                WidgetLimits.bounded(QuickConnectSnapshot(hosts.map { KnownComputer(it.id, it.name.orEmpty()) }, connected, online))
            }
                .distinctUntilChanged()
                .throttled()
                .collectSurvivingFailures(onFailure = ::logFailure) { snapshot ->
                    store.write(snapshot)
                    refresh { QuickConnectWidget().updateAll(appContext) }
                }
        }
        scope.launch {
            active
                .flatMapLatest { session -> session?.let { chatsOf(it) } ?: flowOf(null) }
                .map { open -> merge(open) }
                .distinctUntilChanged { old, new -> old.map(::withoutClock) == new.map(::withoutClock) }
                .throttled()
                .collectSurvivingFailures(onFailure = ::logFailure) { chats ->
                    store.write(AgentsSnapshot(chats, publishedAtSeconds = clock.unixSeconds()))
                    refresh { AgentsWidget().updateAll(appContext) }
                }
        }
    }

    /** A snapshot from a previous process still names the computer that process was connected to. */
    private fun clearConnected() {
        try {
            val last = store.quickConnect()
            if (last.connectedId != null) store.write(last.copy(connectedId = null))
        } catch (failure: RuntimeException) {
            logFailure(failure)
        }
    }

    private fun logFailure(failure: Exception) {
        DebugLog.w(TAG, { "widget publishing failed" }, failure)
    }

    private fun merge(open: Pair<String, List<AgentChatSession>>?): List<AgentChatEntry> {
        if (open == null) {
            book.prune(emptySet())
        } else {
            book.update(open.first, AgentChatEntries.from(open.first.takeUnless { it == NO_HOST }, open.second, clock.unixSeconds()))
        }
        return book.merged()
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private fun chatsOf(session: ActiveSession): Flow<Pair<String, List<AgentChatSession>>?> {
        val hostKey = session.target.hostId ?: NO_HOST
        return session.controller.state.map { it.phase }.distinctUntilChanged().flatMapLatest {
            val chat = session.controller.agentChat
            chat?.state?.map { hostKey to it.sessions } ?: flowOf(hostKey to emptyList())
        }
    }

    private fun withoutClock(entry: AgentChatEntry) = entry.copy(updatedAtSeconds = 0)

    private fun <T> Flow<T>.throttled(): Flow<T> {
        val source = conflate()
        return flow {
            source.collect { value ->
                emit(value)
                delay(MINIMUM_GAP_MILLIS)
            }
        }
    }

    private suspend fun refresh(update: suspend () -> Unit) {
        try {
            update()
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: Exception) {
            DebugLog.w(TAG, { "widget update failed" }, failure)
        }
    }

    private companion object {
        const val TAG = "WidgetPublisher"
        const val NO_HOST = ""
        const val MINIMUM_GAP_MILLIS = 1_000L
    }
}
