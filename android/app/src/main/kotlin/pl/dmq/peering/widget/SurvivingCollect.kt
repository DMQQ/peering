package pl.dmq.peering.widget

import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow

/**
 * Collects [this] and keeps collecting after any non fatal exception from the flow or from [action], so one bad
 * snapshot cannot end the widget updates for the rest of the process. [onFailure] hears each one.
 */
internal suspend fun <T> Flow<T>.collectSurvivingFailures(
    retryDelayMillis: Long = 5_000,
    onFailure: (Exception) -> Unit,
    action: suspend (T) -> Unit,
) {
    while (true) {
        try {
            collect(action)
            return
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            onFailure(failure)
            delay(retryDelayMillis)
        }
    }
}
