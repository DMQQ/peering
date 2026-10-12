package pl.dmq.peering.billing

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.android.billingclient.api.acknowledgePurchase
import com.android.billingclient.api.queryProductDetails
import com.android.billingclient.api.queryPurchasesAsync
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import pl.dmq.peering.session.relay.RelayEntitlement

/**
 * Google Play Billing for relay time. The connection retries through [BillingConnectionPolicy]; when the store cannot
 * give products, [state] says why, and nothing is offered. Purchases are acknowledged when they are seen, and the active
 * one is what each relayed session presents. Calls to [purchase] must come from the main thread, which launches the flow.
 */
class PlayBilling(
    context: Context,
    private val scope: CoroutineScope,
    private val publicKey: () -> ByteArray,
) : Billing {
    private val client: BillingClient = BillingClient.newBuilder(context)
        .setListener(::onPurchasesUpdated)
        .enablePendingPurchases()
        .build()

    private val mutableState = MutableStateFlow<BillingState>(BillingState.Connecting)
    val state: StateFlow<BillingState> = mutableState.asStateFlow()

    private val mutablePaid = MutableStateFlow(false)
    override val paidRelay: StateFlow<Boolean> = mutablePaid.asStateFlow()

    private val mutableEntitlement = MutableStateFlow(RelayEntitlement())

    override fun entitlement(): RelayEntitlement = mutableEntitlement.value

    private var attempt = 1
    private var details: Map<String, ProductDetails> = emptyMap()
    private var pendingPurchase: CompletableDeferred<PurchaseResult>? = null

    fun connect() {
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                continueWith(BillingConnectionPolicy.afterSetup(result.responseCode, attempt))
            }

            override fun onBillingServiceDisconnected() {
                continueWith(BillingConnectionPolicy.afterDisconnect(attempt))
            }
        })
    }

    suspend fun purchase(activity: Activity, productID: String): PurchaseResult {
        val product = details[productID] ?: return PurchaseResult.FAILED
        val productParams = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(product)
        product.subscriptionOfferDetails?.firstOrNull()?.let { productParams.setOfferToken(it.offerToken) }
        val params = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(listOf(productParams.build()))
            .setObfuscatedAccountId(ObfuscatedAccount.of(publicKey()))
            .build()
        val answer = CompletableDeferred<PurchaseResult>()
        pendingPurchase = answer
        val launched = client.launchBillingFlow(activity, params)
        if (launched.responseCode != BillingClient.BillingResponseCode.OK) {
            pendingPurchase = null
            return if (launched.responseCode == BillingClient.BillingResponseCode.USER_CANCELED) {
                PurchaseResult.CANCELLED
            } else {
                PurchaseResult.FAILED
            }
        }
        return answer.await()
    }

    /** Reads what the account owns and says whether pro is among it. A failed read is [RestoreResult.FAILED], not "nothing". */
    suspend fun restore(): RestoreResult {
        val owned = readPurchases() ?: return RestoreResult.FAILED
        return if (activeProPurchase(owned) != null) RestoreResult.RESTORED else RestoreResult.NOTHING_TO_RESTORE
    }

    private fun continueWith(step: ConnectionStep) {
        when (step) {
            ConnectionStep.Connected -> {
                attempt = 1
                scope.launch {
                    loadProducts()
                    readPurchases()
                }
            }
            is ConnectionStep.Retry -> {
                attempt = step.attempt
                scope.launch {
                    delay(step.delayMillis)
                    connect()
                }
            }
            is ConnectionStep.Unavailable -> mutableState.value = BillingState.Unavailable(step.reason)
        }
    }

    private suspend fun loadProducts() {
        val loaded = mutableMapOf<String, ProductDetails>()
        val queries = listOf(
            BillingClient.ProductType.SUBS to PlayProducts.subscriptions,
            BillingClient.ProductType.INAPP to PlayProducts.lifetime,
        )
        for ((type, ids) in queries) {
            val answer = client.queryProductDetails(productQuery(type, ids))
            if (answer.billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
                mutableState.value = BillingState.Unavailable(BillingUnavailable.Refused(answer.billingResult.responseCode))
                return
            }
            answer.productDetailsList.orEmpty().forEach { loaded[it.productId] = it }
        }
        details = loaded
        mutableState.value = if (loaded.isEmpty()) {
            BillingState.Unavailable(BillingUnavailable.NotConfigured)
        } else {
            BillingState.Ready(loaded.values.map { StoreOffer(it.productId, displayPrice(it)) })
        }
    }

    /** The owned purchases, acknowledged where needed; null when Play could not be asked. */
    private suspend fun readPurchases(): List<OwnedPurchase>? {
        val subscriptions = client.queryPurchasesAsync(
            QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build(),
        )
        val oneTime = client.queryPurchasesAsync(
            QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build(),
        )
        if (subscriptions.billingResult.responseCode != BillingClient.BillingResponseCode.OK ||
            oneTime.billingResult.responseCode != BillingClient.BillingResponseCode.OK
        ) {
            return null
        }
        val owned = (subscriptions.purchasesList.orEmpty() + oneTime.purchasesList.orEmpty()).map { it.toOwned() }
        unacknowledged(owned).forEach { acknowledge(it.token) }
        val active = activeProPurchase(owned)
        mutableEntitlement.value = entitlementFor(active)
        mutablePaid.value = active != null
        return owned
    }

    private suspend fun acknowledge(token: String) {
        client.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(token).build())
    }

    private fun onPurchasesUpdated(result: BillingResult, purchases: List<Purchase>?) {
        val outcome = when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> when (purchases?.firstOrNull()?.purchaseState) {
                Purchase.PurchaseState.PURCHASED -> PurchaseResult.PURCHASED
                Purchase.PurchaseState.PENDING -> PurchaseResult.PENDING
                else -> PurchaseResult.FAILED
            }
            BillingClient.BillingResponseCode.USER_CANCELED -> PurchaseResult.CANCELLED
            else -> PurchaseResult.FAILED
        }
        pendingPurchase?.complete(outcome)
        pendingPurchase = null
        scope.launch { readPurchases() }
    }

    private fun Purchase.toOwned(): OwnedPurchase = OwnedPurchase(
        productID = products.firstOrNull().orEmpty(),
        token = purchaseToken,
        purchased = purchaseState == Purchase.PurchaseState.PURCHASED,
        acknowledged = isAcknowledged,
    )

    private fun productQuery(type: String, ids: List<String>): QueryProductDetailsParams =
        QueryProductDetailsParams.newBuilder()
            .setProductList(ids.map { QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(type).build() })
            .build()

    private fun displayPrice(product: ProductDetails): String =
        product.subscriptionOfferDetails?.firstOrNull()?.pricingPhases?.pricingPhaseList?.lastOrNull()?.formattedPrice
            ?: product.oneTimePurchaseOfferDetails?.formattedPrice.orEmpty()
}
