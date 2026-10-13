package pl.dmq.peering.billing

enum class PurchaseResult {
    PURCHASED,
    PENDING,
    CANCELLED,
    FAILED,
}

enum class RestoreResult {
    RESTORED,
    NOTHING_TO_RESTORE,
    FAILED,
}
