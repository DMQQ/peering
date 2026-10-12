package pl.dmq.peering

import kotlinx.coroutines.CoroutineExceptionHandler

private const val TAG = "PeeringScope"

/**
 * Keeps the process alive when a coroutine fails with an error the app can live through, such as a discovery or socket
 * failure. A [VirtualMachineError] (out of memory, stack overflow) is thrown again, so it still ends the process.
 */
internal fun survivableErrorHandler(
    log: (Throwable) -> Unit = { error -> DebugLog.w(TAG, { "a coroutine failed and was contained" }, error) },
): CoroutineExceptionHandler = CoroutineExceptionHandler { _, error ->
    if (error is VirtualMachineError) throw error
    log(error)
}
