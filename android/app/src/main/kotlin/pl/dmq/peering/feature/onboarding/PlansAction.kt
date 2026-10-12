package pl.dmq.peering.feature.onboarding

/** What the tour's one button does: turn the page, leave the first run, or start buying the chosen plan. */
internal enum class PlansAction { Next, Finish, Buy }

/**
 * Free, or a store that offered nothing to buy, or a plan already owned, all end the first run: the page only asks
 * about money, it never holds the app back.
 */
internal fun plansAction(onPlans: Boolean, freeChosen: Boolean, entitled: Boolean, hasProducts: Boolean): PlansAction = when {
    !onPlans -> PlansAction.Next
    freeChosen || entitled || !hasProducts -> PlansAction.Finish
    else -> PlansAction.Buy
}
