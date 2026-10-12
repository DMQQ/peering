package pl.dmq.peering.feature.connect

/** What the Nearby section has to say, in the order the checks run. */
enum class NearbyPhase {
    NoNetwork,
    Found,
    Searching,
    NoneFound;

    companion object {
        fun of(onLocalNetwork: Boolean, nearbyCount: Int, searching: Boolean): NearbyPhase = when {
            !onLocalNetwork -> NoNetwork
            nearbyCount > 0 -> Found
            searching -> Searching
            else -> NoneFound
        }
    }
}
