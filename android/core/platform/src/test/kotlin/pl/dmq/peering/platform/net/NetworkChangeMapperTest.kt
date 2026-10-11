package pl.dmq.peering.platform.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NetworkChangeMapperTest {
    private val wifi = NetworkSnapshot(connected = true, transport = TransportKind.WIFI)
    private val cellular = NetworkSnapshot(connected = true, transport = TransportKind.CELLULAR)
    private val offline = NetworkSnapshot(connected = false, transport = null)

    @Test
    fun firstConnectionIsAvailable() {
        assertEquals(NetworkChange.Available(TransportKind.WIFI), NetworkChangeMapper().changeFor(wifi))
    }

    @Test
    fun connectingOverCellularIsAvailableOverCellular() {
        assertEquals(NetworkChange.Available(TransportKind.CELLULAR), NetworkChangeMapper().changeFor(cellular))
    }

    @Test
    fun startingOfflineReportsNothing() {
        assertNull(NetworkChangeMapper().changeFor(offline))
    }

    @Test
    fun losingTheNetworkIsLost() {
        val mapper = NetworkChangeMapper()
        mapper.changeFor(wifi)

        assertEquals(NetworkChange.Lost, mapper.changeFor(offline))
    }

    @Test
    fun repeatedConnectedStateIsIgnored() {
        val mapper = NetworkChangeMapper()
        mapper.changeFor(wifi)

        assertNull(mapper.changeFor(wifi))
    }

    @Test
    fun repeatedOfflineStateIsIgnored() {
        val mapper = NetworkChangeMapper()
        mapper.changeFor(wifi)
        mapper.changeFor(offline)

        assertNull(mapper.changeFor(offline))
    }

    @Test
    fun switchingTransportIsAPathChange() {
        val mapper = NetworkChangeMapper()
        mapper.changeFor(wifi)

        assertEquals(NetworkChange.PathChanged(TransportKind.CELLULAR), mapper.changeFor(cellular))
    }

    @Test
    fun reconnectingAfterLossIsAvailableAgain() {
        val mapper = NetworkChangeMapper()
        mapper.changeFor(wifi)
        mapper.changeFor(offline)

        assertEquals(NetworkChange.Available(TransportKind.WIFI), mapper.changeFor(wifi))
    }

    @Test
    fun transportKindPrefersWifiWhenBothAreUp() {
        assertEquals(TransportKind.WIFI, TransportKind.from(wifi = true, cellular = true))
        assertEquals(TransportKind.CELLULAR, TransportKind.from(wifi = false, cellular = true))
        assertEquals(TransportKind.OTHER, TransportKind.from(wifi = false, cellular = false))
    }
}
