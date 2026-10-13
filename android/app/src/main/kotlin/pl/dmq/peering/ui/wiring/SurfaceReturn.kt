package pl.dmq.peering.ui.wiring

/**
 * Decides when a returning picture surface needs the stream reopened. A new decoder cannot start on a delta frame, so
 * after a surface that had a picture goes and comes back, the host has to send a keyframe again.
 */
internal class SurfaceReturn {
    private var lostPicture = false

    fun gone(hadPicture: Boolean) {
        if (hadPicture) lostPicture = true
    }

    /** True once for each return that follows a lost picture. */
    fun available(): Boolean = lostPicture.also { lostPicture = false }
}
