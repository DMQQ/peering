package pl.dmq.peering.feature.paywall

import pl.dmq.peering.billing.BillingUnavailable

/** Thrown by a store that cannot give the offers. The paywall shows the reason instead of a list of plans. */
class PaywallUnavailable(val reason: BillingUnavailable) : Exception()
