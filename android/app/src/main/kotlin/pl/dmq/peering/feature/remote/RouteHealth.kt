package pl.dmq.peering.feature.remote

/** The colour class of the route pill's dot. */
enum class RouteHealth {
    GOOD,
    DEGRADED,
    BROKEN,
    UNKNOWN,
    ;

    companion object {
        fun of(state: SessionOverlayState): RouteHealth = when {
            state.reconnecting || state.picture == PictureState.STALLED || state.picture == PictureState.PAUSED -> DEGRADED
            state.picture == PictureState.FAILED -> BROKEN
            state.picture == PictureState.LIVE -> GOOD
            else -> UNKNOWN
        }
    }
}
