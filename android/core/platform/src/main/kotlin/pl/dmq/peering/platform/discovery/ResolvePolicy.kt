package pl.dmq.peering.platform.discovery

/** When a failed NsdManager resolve is tried again. Codes are NsdManager's FAILURE_* constants. */
internal object ResolvePolicy {
    const val FAILURE_INTERNAL_ERROR = 0
    const val FAILURE_ALREADY_ACTIVE = 3
    const val FAILURE_MAX_LIMIT = 4
    private const val MAX_RETRIES = 4
    private const val STEP_MILLIS = 250L

    /** How long to wait before retry number [attempt] (from 0), or null to give up. */
    fun retryDelayMillis(errorCode: Int, attempt: Int): Long? {
        if (attempt >= MAX_RETRIES) return null
        return when (errorCode) {
            FAILURE_ALREADY_ACTIVE, FAILURE_MAX_LIMIT -> STEP_MILLIS * (attempt + 1)
            FAILURE_INTERNAL_ERROR -> if (attempt == 0) STEP_MILLIS else null
            else -> null
        }
    }
}
