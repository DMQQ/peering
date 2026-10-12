package pl.dmq.peering.feature.remote

/** Whether the top bar and the action bar are drawn. They stay up unless the user chose immersive mode. */
object ChromePolicy {
    /** Immersive mode still shows the chrome while the picture or link needs attention, so retry stays reachable. */
    fun shown(immersive: Boolean, picture: PictureState, reconnecting: Boolean): Boolean =
        !immersive || reconnecting || picture != PictureState.LIVE
}
