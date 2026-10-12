package pl.dmq.peering.feature.remote

/** When the session chrome may fold away on its own. */
object ChromePolicy {
    const val AUTO_HIDE_MS = 5000L

    /** The chrome stays while the user is typing, a sheet is open, or the picture or link needs attention. */
    fun holdsChrome(
        keyboardShown: Boolean,
        overlayOpen: Boolean,
        picture: PictureState,
        reconnecting: Boolean,
    ): Boolean = keyboardShown || overlayOpen || reconnecting || picture != PictureState.LIVE
}
