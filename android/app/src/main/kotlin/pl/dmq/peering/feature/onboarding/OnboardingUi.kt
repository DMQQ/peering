package pl.dmq.peering.feature.onboarding

data class OnboardingUi(
    val step: OnboardingStep,
    val completed: Boolean,
) {
    val isLast: Boolean get() = step.next() == null
}
