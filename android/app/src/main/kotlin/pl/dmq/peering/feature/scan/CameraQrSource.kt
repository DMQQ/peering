package pl.dmq.peering.feature.scan

import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import pl.dmq.peering.feature.pairing.QrSource

/** Codes the camera read, handed to the pairing entry. Nothing is read unless the scanner screen is open. */
class CameraQrSource : QrSource {
    private val reads = MutableSharedFlow<String>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    override fun scans(): Flow<String> = reads.asSharedFlow()

    fun offer(text: String) {
        reads.tryEmit(text)
    }
}
