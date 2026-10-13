package pl.dmq.peering.billing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BillingPureTest {
    private fun purchase(id: String, purchased: Boolean = true, acknowledged: Boolean = true, token: String = "tok-$id") =
        OwnedPurchase(productID = id, token = token, purchased = purchased, acknowledged = acknowledged)

    @Test
    fun theProductIdsAreTheAppStoreIds() {
        assertEquals("pl.dmq.peering.iap.pro.monthly", PlayProducts.PRO_MONTHLY)
        assertEquals("pl.dmq.peering.iap.pro.year", PlayProducts.PRO_YEARLY)
        assertEquals("pl.dmq.peering.iap.pro.lifetime1", PlayProducts.PRO_LIFETIME)
        assertEquals(setOf(PlayProducts.PRO_MONTHLY, PlayProducts.PRO_YEARLY, PlayProducts.PRO_LIFETIME), PlayProducts.paid)
    }

    @Test
    fun aPaidPurchaseIsTheActiveProOne() {
        val active = activeProPurchase(listOf(purchase("other"), purchase(PlayProducts.PRO_YEARLY)))
        assertEquals(PlayProducts.PRO_YEARLY, active?.productID)
    }

    @Test
    fun aPendingOrUnknownPurchaseGrantsNothing() {
        assertNull(activeProPurchase(listOf(purchase(PlayProducts.PRO_MONTHLY, purchased = false))))
        assertNull(activeProPurchase(listOf(purchase("unknown.product"))))
        assertNull(activeProPurchase(emptyList()))
    }

    @Test
    fun theEntitlementCarriesThePlanTokenAndProduct() {
        val entitlement = entitlementFor(purchase(PlayProducts.PRO_LIFETIME, token = "abc"))
        assertEquals("pro", entitlement.plan)
        assertEquals("abc", entitlement.playPurchaseToken)
        assertEquals(PlayProducts.PRO_LIFETIME, entitlement.playProductId)
    }

    @Test
    fun withoutAPurchaseTheRelayGetsNoPlan() {
        val entitlement = entitlementFor(null)
        assertNull(entitlement.plan)
        assertNull(entitlement.playPurchaseToken)
        assertNull(entitlement.playProductId)
    }

    @Test
    fun onlyPurchasedAndUnacknowledgedOnesAreAcknowledged() {
        val pending = listOf(
            purchase("a", acknowledged = false),
            purchase("b", acknowledged = true),
            purchase("c", purchased = false, acknowledged = false),
        )
        assertEquals(listOf("a"), unacknowledged(pending).map { it.productID })
    }

    @Test
    fun theObfuscatedAccountIsTheSha256HexOfTheKey() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ObfuscatedAccount.of("abc".toByteArray()),
        )
    }

    @Test
    fun aSuccessfulSetupConnects() {
        assertEquals(ConnectionStep.Connected, BillingConnectionPolicy.afterSetup(BillingConnectionPolicy.RESPONSE_OK, 1))
    }

    @Test
    fun aStoreThatIsNotReadyIsRetriedWithALongerWaitEachTime() {
        val first = BillingConnectionPolicy.afterSetup(BillingConnectionPolicy.RESPONSE_SERVICE_UNAVAILABLE, 1)
        val second = BillingConnectionPolicy.afterSetup(BillingConnectionPolicy.RESPONSE_SERVICE_UNAVAILABLE, 2)
        assertEquals(ConnectionStep.Retry(attempt = 2, delayMillis = 1_000), first)
        assertEquals(ConnectionStep.Retry(attempt = 3, delayMillis = 2_000), second)
    }

    @Test
    fun aStoreThatStaysUnreachableGivesUpAfterTheLastAttempt() {
        val gaveUp = BillingConnectionPolicy.afterDisconnect(BillingConnectionPolicy.MAX_ATTEMPTS)
        assertEquals(ConnectionStep.Unavailable(BillingUnavailable.StoreUnreachable), gaveUp)
    }

    @Test
    fun aDeviceWithoutBillingIsUnavailableAtOnce() {
        val step = BillingConnectionPolicy.afterSetup(BillingConnectionPolicy.RESPONSE_FEATURE_NOT_SUPPORTED, 1)
        assertEquals(ConnectionStep.Unavailable(BillingUnavailable.NotSupported), step)
    }

    @Test
    fun anUnexpectedAnswerIsReportedWithItsCode() {
        val step = BillingConnectionPolicy.afterSetup(5, 1)
        assertEquals(ConnectionStep.Unavailable(BillingUnavailable.Refused(5)), step)
    }
}
