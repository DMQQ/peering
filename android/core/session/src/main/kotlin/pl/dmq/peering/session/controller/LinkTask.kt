package pl.dmq.peering.session.controller

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Runs one task of a control connection. However the task ends, the connection is over, so the link ends as
 * [LinkEnd.Lost]. A failure of the task reads the same way, and is noted by its type only, since its message can carry an address.
 */
internal fun CoroutineScope.launchLinkTask(
    ended: CompletableDeferred<LinkEnd>,
    note: (String) -> Unit,
    task: suspend () -> Unit,
) {
    launch {
        try {
            task()
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (failure: Exception) {
            note("a link task failed with ${failure.javaClass.simpleName}")
            ended.complete(LinkEnd.Lost)
            return@launch
        }
        ended.complete(LinkEnd.Lost)
    }
}
