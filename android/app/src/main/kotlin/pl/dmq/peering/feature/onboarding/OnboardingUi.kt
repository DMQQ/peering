package pl.dmq.peering.feature.onboarding

data class OnboardingUi(
    val step: OnboardingStep,
    val completed: Boolean,
) {
    val stepNumber: Int get() = step.ordinal + 1

    val stepCount: Int get() = OnboardingStep.count

    val canGoBack: Boolean get() = step.previous() != null

    val isLastStep: Boolean get() = step.next() == null
}
