package pl.dmq.peering.feature.paywall

/** The allowance screen: whether the relay has stopped a session for lack of time, and what is left today. */
data class AllowanceUi(
    val spent: Boolean,
    val paid: Boolean,
    val remaining: RemainingLabel,
    val dailyLimit: RemainingLabel,
) {
    companion object {
        fun of(allowance: RelayAllowance): AllowanceUi = AllowanceUi(
            spent = allowance.isSpent,
            paid = allowance.paid,
            remaining = RemainingLabel.of(allowance.remainingSeconds),
            dailyLimit = RemainingLabel.of(allowance.dailyLimitSeconds),
        )
    }
}
