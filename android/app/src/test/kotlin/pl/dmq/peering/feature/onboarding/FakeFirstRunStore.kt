package pl.dmq.peering.feature.onboarding

class FakeFirstRunStore(private var complete: Boolean = false) : FirstRunStore {
    var marks = 0
        private set

    override fun isComplete(): Boolean = complete

    override fun markComplete() {
        complete = true
        marks++
    }
}
