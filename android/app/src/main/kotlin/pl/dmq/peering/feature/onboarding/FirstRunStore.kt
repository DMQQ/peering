package pl.dmq.peering.feature.onboarding

/** Remembers that the first run was finished or skipped, so it is not shown again. */
interface FirstRunStore {
    fun isComplete(): Boolean

    fun markComplete()
}
