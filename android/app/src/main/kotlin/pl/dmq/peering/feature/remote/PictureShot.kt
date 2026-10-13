package pl.dmq.peering.feature.remote

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.Window
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/** The view that shows the picture, set while it exists, for the screenshot to read. Main thread only. */
class PictureViewHolder {
    var view: SurfaceView? = null
}

/** A copy of the remote picture as a PNG. */
internal object PictureShot {
    /**
     * Copies what [view] shows. The window is secure while a session is on screen, which blacks the picture out of any
     * capture, so the flag is lifted for the copy only and put back afterwards. Null when there is no picture or the copy failed.
     */
    suspend fun png(view: SurfaceView?, window: Window): ByteArray? {
        view ?: return null
        if (view.width <= 0 || view.height <= 0) return null
        val wasSecure = window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0
        if (wasSecure) {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            delay(SECURE_SETTLE_MILLIS)
        }
        try {
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            val copied = copy(view, bitmap)
            return if (copied) withContext(Dispatchers.Default) { encode(bitmap) } else null
        } finally {
            if (wasSecure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    private suspend fun copy(view: SurfaceView, bitmap: Bitmap): Boolean = suspendCancellableCoroutine { done ->
        PixelCopy.request(view, bitmap, { result -> done.resume(result == PixelCopy.SUCCESS) }, Handler(Looper.getMainLooper()))
    }

    private fun encode(bitmap: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, PNG_QUALITY, out)
        return out.toByteArray()
    }

    /** The window server applies a cleared flag a frame or two later. */
    private const val SECURE_SETTLE_MILLIS = 120L
    private const val PNG_QUALITY = 100
}
