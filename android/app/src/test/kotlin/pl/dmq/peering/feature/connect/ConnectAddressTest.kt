package pl.dmq.peering.feature.connect

import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.pairing.FakeQrSource

class ConnectAddressTest {
    private fun kotlinx.coroutines.test.TestScope.presenter(dialled: MutableList<ManualAddress>) = ConnectPresenter(
        hosts = FakeHostSource(),
        presence = FakePresenceSource(),
        qrSource = FakeQrSource(),
        onConnect = { _ -> },
        onPair = { _ -> },
        onConnectAddress = { dialled += it },
        scope = backgroundScope,
    )

    @Test
    fun aTypedAddressIsDialledWithTheDefaultPortWhenNoneIsGiven() = runTest(UnconfinedTestDispatcher()) {
        val dialled = mutableListOf<ManualAddress>()

        presenter(dialled).connectToAddress("192.168.1.20", "")

        assertEquals(listOf(ManualAddress("192.168.1.20", ManualAddress.DEFAULT_PORT)), dialled)
    }

    @Test
    fun fieldsThatAreNotAnAddressDialNothing() = runTest(UnconfinedTestDispatcher()) {
        val dialled = mutableListOf<ManualAddress>()
        val connect = presenter(dialled)

        connect.connectToAddress("", "51515")
        connect.connectToAddress("mac.local", "99999")

        assertTrue(dialled.isEmpty())
    }
}
