package pl.dmq.peering.feature.onboarding

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * The minimal first run: three steps in order, and a flag in [store] set once the user finishes or skips them. A
 * completed first run stays completed, so a later launch does not show it again.
 */
class OnboardingPresenter(
    private val store: FirstRunStore,
) {
    private val model = MutableStateFlow(OnboardingUi(step = OnboardingStep.WHAT_IS_PEERING, completed = store.isComplete()))
    val ui: StateFlow<OnboardingUi> = model.asStateFlow()

    fun next() {
        val current = model.value
        if (current.completed) return
        val following = current.step.next()
        if (following == null) finish() else model.update { it.copy(step = following) }
    }

    fun back() {
        val previous = model.value.step.previous() ?: return
        model.update { it.copy(step = previous) }
    }

    fun skip() = finish()

    private fun finish() {
        if (model.value.completed) return
        store.markComplete()
        model.update { it.copy(completed = true) }
    }
}
