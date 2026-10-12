package pl.dmq.peering.feature.onboarding

enum class OnboardingStep {
    WHAT_IS_PEERING,
    INSTALL_HOST,
    SCAN_CODE,
    ;

    fun next(): OnboardingStep? = entries.getOrNull(ordinal + 1)

    fun previous(): OnboardingStep? = entries.getOrNull(ordinal - 1)

    companion object {
        val count: Int get() = entries.size
    }
}
