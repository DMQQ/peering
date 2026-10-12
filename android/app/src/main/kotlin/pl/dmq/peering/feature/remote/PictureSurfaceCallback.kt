package pl.dmq.peering.feature.remote

import android.view.SurfaceHolder

internal class PictureSurfaceCallback(private val listener: SurfaceListener) : SurfaceHolder.Callback {
    override fun surfaceCreated(holder: SurfaceHolder) {
        listener.onSurfaceAvailable(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        listener.onSurfaceSizeChanged(width, height)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        listener.onSurfaceGone()
    }
}
