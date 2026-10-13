package pl.dmq.peering.billing

/**
 * The Play product ids for relay time. They are the App Store ids, so one plan reads the same on both stores. The
 * subscriptions are in one group on Play, so moving between them is an upgrade or a downgrade, not a second subscription.
 */
object PlayProducts {
    private const val STEM = "pl.dmq.peering.iap"

    const val PRO_MONTHLY = "$STEM.pro.monthly"
    const val PRO_YEARLY = "$STEM.pro.year"
    const val PRO_LIFETIME = "$STEM.pro.lifetime1"

    val subscriptions: List<String> = listOf(PRO_MONTHLY, PRO_YEARLY)

    val lifetime: List<String> = listOf(PRO_LIFETIME)

    /** Every id that grants unlimited relay time. */
    val paid: Set<String> = (subscriptions + lifetime).toSet()
}
