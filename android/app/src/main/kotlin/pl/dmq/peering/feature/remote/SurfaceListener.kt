package pl.dmq.peering.feature.remote

import android.view.Surface

/** Told when the picture's surface appears, resizes or goes, so a decoder can draw into it. */
interface SurfaceListener {
    fun onSurfaceAvailable(surface: Surface)

    fun onSurfaceSizeChanged(width: Int, height: Int)

    fun onSurfaceGone()
}
