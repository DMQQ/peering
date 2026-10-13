package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.history.SessionRecord

/** True while the session in front of the phone is ready on the relay, the only path that spends relay time. */
internal fun relayInUse(sessions: Flow<ActiveSession?>): Flow<Boolean> = sessions.flatMapLatest { session ->
    session?.controller?.state?.map { state ->
        (state.phase as? SessionPhase.Ready)?.path == SessionRecord.Path.RELAY
    } ?: flowOf(false)
}.distinctUntilChanged()
