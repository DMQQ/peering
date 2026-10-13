package pl.dmq.peering.feature.onboarding

/** The landing, then the tour's eight pages in order. The last page is the plans. */
enum class OnboardingStep {
    LANDING,
    INSTALL,
    PAIR,
    SOURCES,
    CONTROLS,
    FOLLOWS,
    MOSAIC,
    NOTIFICATIONS,
    PLANS,
    ;

    val isTourPage: Boolean get() = this != LANDING

    /** Zero based position among the tour's pages, or null on the landing. */
    val pageIndex: Int? get() = if (isTourPage) ordinal - 1 else null

    fun next(): OnboardingStep? = entries.getOrNull(ordinal + 1)

    fun previous(): OnboardingStep? = entries.getOrNull(ordinal - 1)

    companion object {
        val pageCount: Int get() = entries.size - 1
    }
}
