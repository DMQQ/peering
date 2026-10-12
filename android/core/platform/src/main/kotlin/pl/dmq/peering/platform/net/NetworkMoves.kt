package pl.dmq.peering.platform.net

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
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
    changes().movesOnly(startedOnline = isOnline()).onEach { onMoved() }.launchIn(scope)

internal fun Flow<NetworkChange>.movesOnly(startedOnline: Boolean = true): Flow<NetworkChange> =
    (if (startedOnline) drop(1) else this).filter { it !is NetworkChange.Lost }
