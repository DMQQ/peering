package pl.dmq.peering.feature.remote

/** Whether the top bar and the action bar are drawn. They stay up unless the user chose immersive mode. */
object ChromePolicy {
    /** Immersive mode still shows the chrome while the picture or link needs attention, so retry stays reachable. */
    fun shown(immersive: Boolean, picture: PictureState, reconnecting: Boolean): Boolean =
        !immersive || reconnecting || picture != PictureState.LIVE

    /** The joystick and the scroll wheel steer the computer's pointer, which a mosaic does not take. */
    fun pointerControlsShown(keyboardShown: Boolean, mosaic: Boolean): Boolean = !keyboardShown && !mosaic

    /** The pointer glyph is the computer's own; a mosaic has no single pointer to draw. */
    fun cursorShown(interaction: InputMode, picture: PictureState, mosaic: Boolean): Boolean =
        interaction != InputMode.OBSERVE && picture == PictureState.LIVE && !mosaic
}
