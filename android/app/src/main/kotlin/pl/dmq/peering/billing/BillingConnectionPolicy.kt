package pl.dmq.peering.billing

/** What the store connection does after one answer from Play or a dropped link. */
sealed interface ConnectionStep {
    data object Connected : ConnectionStep

    /** Try again after [delayMillis]; [attempt] is the number of the try that follows. */
    data class Retry(val attempt: Int, val delayMillis: Long) : ConnectionStep

    data class Unavailable(val reason: BillingUnavailable) : ConnectionStep
}

/** Maps the response codes of the Play Billing Library onto the connection's next step. Pure: no SDK types. */
object BillingConnectionPolicy {
    const val RESPONSE_OK = 0
    const val RESPONSE_SERVICE_UNAVAILABLE = 2
    const val RESPONSE_BILLING_UNAVAILABLE = 3
    const val RESPONSE_NETWORK_ERROR = 12
    const val RESPONSE_SERVICE_DISCONNECTED = -1
    const val RESPONSE_FEATURE_NOT_SUPPORTED = -2

    const val MAX_ATTEMPTS = 3
    private const val BASE_DELAY_MILLIS = 1_000L

    fun afterSetup(responseCode: Int, attempt: Int): ConnectionStep = when (responseCode) {
        RESPONSE_OK -> ConnectionStep.Connected
        RESPONSE_SERVICE_UNAVAILABLE, RESPONSE_SERVICE_DISCONNECTED, RESPONSE_NETWORK_ERROR -> retryOrGiveUp(attempt)
        RESPONSE_BILLING_UNAVAILABLE, RESPONSE_FEATURE_NOT_SUPPORTED -> ConnectionStep.Unavailable(BillingUnavailable.NotSupported)
        else -> ConnectionStep.Unavailable(BillingUnavailable.Refused(responseCode))
    }

    /** The link to the store dropped: reconnect on the same ladder as a failed setup. */
    fun afterDisconnect(attempt: Int): ConnectionStep = retryOrGiveUp(attempt)

    private fun retryOrGiveUp(attempt: Int): ConnectionStep =
        if (attempt < MAX_ATTEMPTS) {
            ConnectionStep.Retry(attempt + 1, BASE_DELAY_MILLIS shl (attempt - 1))
        } else {
            ConnectionStep.Unavailable(BillingUnavailable.StoreUnreachable)
        }
}
