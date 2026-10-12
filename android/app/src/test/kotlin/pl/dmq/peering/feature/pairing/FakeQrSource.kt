package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

class FakeQrSource(private val scanned: Flow<String> = emptyFlow()) : QrSource {
    override fun scans(): Flow<String> = scanned
}
