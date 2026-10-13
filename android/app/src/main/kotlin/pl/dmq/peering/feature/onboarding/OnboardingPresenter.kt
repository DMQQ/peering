package pl.dmq.peering.feature.onboarding

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * The first run: a landing and a tour that ends on the plans, and a flag in [store] set once the user finishes or skips
 * it. A completed first run stays completed, so a later launch does not show it again.
 */
class OnboardingPresenter(
    private val store: FirstRunStore,
    startAt: OnboardingStep = OnboardingStep.LANDING,
) {
    private val model = MutableStateFlow(OnboardingUi(step = startAt, completed = store.isComplete()))
    val ui: StateFlow<OnboardingUi> = model.asStateFlow()

    fun next() {
        val current = model.value
        if (current.completed) return
        val following = current.step.next()
        if (following == null) finish() else model.update { it.copy(step = following) }
    }

    fun goTo(step: OnboardingStep) {
        if (model.value.completed || !step.isTourPage) return
        model.update { it.copy(step = step) }
    }

    /** One step back, the first tour page returning to the landing. False on the landing, where back leaves the first run's screen. */
    fun back(): Boolean {
        val current = model.value
        val earlier = current.step.previous()
        if (current.completed || earlier == null) return false
        model.update { it.copy(step = earlier) }
        return true
    }

    /** From the landing it leaves the first run; inside the tour it jumps to the plans, the page every route ends on. */
    fun skip() {
        val step = model.value.step
        if (step == OnboardingStep.LANDING || step == OnboardingStep.PLANS) finish() else goTo(OnboardingStep.PLANS)
    }

    fun finish() {
        if (model.value.completed) return
        store.markComplete()
        model.update { it.copy(completed = true) }
    }
}
