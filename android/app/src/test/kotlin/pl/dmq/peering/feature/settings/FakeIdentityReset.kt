package pl.dmq.peering.feature.settings

class FakeIdentityReset(private val succeeds: Boolean = true) : IdentityReset {
    var resets = 0
        private set

    override fun reset(): Boolean {
        resets++
        return succeeds
    }
}
