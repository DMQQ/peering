package pl.dmq.peering.wire

/** What the relay says about this device's invite code and the extra daily relay time it has earned. Times are Unix seconds. */
data class RelayReferral(
    val code: String,
    /** Added to each daily window right now: zero once every grant has ended. */
    val bonusSeconds: Long,
    /** When the last running grant ends, or null with none running. */
    val bonusEndsAt: Long?,
    /** Whether this device has redeemed somebody's code. Allowed once, ever. */
    val redeemed: Boolean,
    val invitesEarned: Int,
    val invitesMax: Int,
) {
    /** The extra seconds that count at [nowSeconds]: nothing once the last grant has ended. */
    fun activeBonusSeconds(nowSeconds: Long): Long = if (bonusEndsAt != null && bonusEndsAt > nowSeconds) bonusSeconds else 0
}

/** An invite code as a person types and reads it. */
object ReferralCode {
    const val LENGTH = 8

    /** Eight characters, no separators, upper case: what the relay compares against. People type spaces, hyphens and lower case. */
    fun canonical(typed: String): String = typed.uppercase().filter { it.isLetterOrDigit() }

    fun isComplete(typed: String): Boolean = canonical(typed).length == LENGTH

    /** `ABCD-EFGH`: two groups of four read and dictate more easily than eight in a row. */
    fun display(code: String): String {
        val plain = canonical(code)
        return if (plain.length == LENGTH) "${plain.take(4)}-${plain.takeLast(4)}" else plain
    }
}

/** Why the relay turned a redemption away, from its error `code`. */
enum class ReferralRefusal {
    UnknownCode,
    OwnCode,
    AlreadyRedeemed,
    NeedsKeyProof,
    Busy,
    Unavailable,
    ;

    companion object {
        fun of(code: String): ReferralRefusal = when (code) {
            "referralUnknownCode" -> UnknownCode
            "referralOwnCode" -> OwnCode
            "referralAlreadyRedeemed" -> AlreadyRedeemed
            "proofRequired", "proofStale", "proofInvalid" -> NeedsKeyProof
            "referralsBusy", "tooManyRequests" -> Busy
            else -> Unavailable
        }
    }
}
