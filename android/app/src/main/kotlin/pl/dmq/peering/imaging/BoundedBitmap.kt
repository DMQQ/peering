package pl.dmq.peering.imaging

import android.graphics.Bitmap
import android.graphics.BitmapFactory

/** Decoding that cannot take the app down: pictures are sampled to a pixel budget and an out of memory is a null. */
internal object BoundedBitmap {
    /** Null when the bytes are not a picture or there was no memory to decode it. */
    fun decode(bytes: ByteArray, maxPixels: Long = MAX_DECODE_PIXELS): Bitmap? = decodeSampled(bytes) { width, height ->
        ImageSampling.sampleSize(width, height, maxPixels)
    }

    /** A bitmap whose longer side is at least [edge] pixels, as small as sampling allows. */
    fun thumbnail(bytes: ByteArray, edge: Int): Bitmap? = decodeSampled(bytes) { width, height ->
        maxOf(ImageSampling.sampleForEdge(width, height, edge), ImageSampling.sampleSize(width, height))
    }

    private fun decodeSampled(bytes: ByteArray, sampleFor: (width: Int, height: Int) -> Int): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            null
        } else {
            val options = BitmapFactory.Options().apply { inSampleSize = sampleFor(bounds.outWidth, bounds.outHeight) }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        }
    } catch (_: OutOfMemoryError) {
        null
    }
}
