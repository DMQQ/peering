package pl.dmq.peering.feature.connect

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf

/** Whether this phone is on a network a Mac can be found on (Wi-Fi or Ethernet), which mobile data alone is not. */
interface NetworkSource {
    fun onLocalNetwork(): Flow<Boolean>

    companion object {
        val Always: NetworkSource = object : NetworkSource {
            override fun onLocalNetwork(): Flow<Boolean> = flowOf(true)
        }
    }
}
