package pl.dmq.peering.feature.scan

import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy

/** Decodes each camera frame's luminance and passes a new code to [onCode]. Runs on the analysis thread. */
internal class QrFrameAnalyzer(
    private val onCode: (String) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
) : ImageAnalysis.Analyzer {
    private val repeats = ScanRepeatFilter()

    override fun analyze(image: ImageProxy) {
        try {
            val plane = image.planes.first()
            val buffer = plane.buffer
            val bytes = ByteArray(buffer.remaining()).also { buffer.get(it) }
            val luminance = compactLuminanceRows(bytes, plane.rowStride, image.width, image.height)
            QrDecoder.decode(luminance, image.width, image.height)
                ?.takeIf { repeats.accept(it, clock()) }
                ?.let(onCode)
        } finally {
            image.close()
        }
    }
}
