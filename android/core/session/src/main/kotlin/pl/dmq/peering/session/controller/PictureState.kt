package pl.dmq.peering.session.controller

/**
 * What the picture area should show: waiting for the first frame, live, paused by the user, carried by the fallback,
 * stalled with nothing received for too long, or failed because the picture's connection could not be kept.
 */
sealed interface PictureState {
    data object Connecting : PictureState

    data object Live : PictureState

    data object Paused : PictureState

    data object Fallback : PictureState

    /** The first frame has not arrived in time. The session is still up, so a retry can reopen the picture. */
    data object Stalled : PictureState

    data class Failed(val reason: PictureFailure) : PictureState
}

/** Why the local picture connection gave up after its reconnect ladder was spent. */
enum class PictureFailure { CouldNotOpen, Dropped }
