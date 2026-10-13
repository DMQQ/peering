package pl.dmq.peering.platform.net

import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

/**
 * Calls [onMoved] each time the default network changes to another usable one, as the iPhone dials again on a new path
 * and not on a lost one. The first event only reports the network the collection began on, and a lost network is not a
 * move: there is nothing to dial on until another becomes available. A collection that began offline has no starting
 * network, so its first event is a move.
 */
fun NetworkWatcher.followMoves(scope: CoroutineScope, onMoved: () -> Unit): Job =
    changes().followMoves(scope, startedOnline = isOnline(), onMoved)

/** Registering the network callback can throw (a missing permission, or the system service gone); the session then just never hears of moves. */
internal fun Flow<NetworkChange>.followMoves(scope: CoroutineScope, startedOnline: Boolean = true, onMoved: () -> Unit): Job =
    movesOnly(startedOnline).onEach { onMoved() }.catch { failure -> if (failure is CancellationException || failure !is RuntimeException) throw failure }.launchIn(scope)

internal fun Flow<NetworkChange>.movesOnly(startedOnline: Boolean = true): Flow<NetworkChange> =
    (if (startedOnline) drop(1) else this).filter { it !is NetworkChange.Lost }
