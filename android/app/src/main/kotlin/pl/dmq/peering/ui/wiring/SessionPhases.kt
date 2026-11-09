package pl.dmq.peering.ui.wiring

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import pl.dmq.peering.session.controller.SessionPhase

/** The phase of whichever session is showing, or null while there is none. */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun sessionPhases(active: Flow<ActiveSession?>): Flow<SessionPhase?> =
    active.flatMapLatest { session -> session?.controller?.state?.map { it.phase } ?: flowOf(null) }
