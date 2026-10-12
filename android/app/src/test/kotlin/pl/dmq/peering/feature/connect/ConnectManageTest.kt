package pl.dmq.peering.feature.connect

import kotlinx.coroutines.CoroutineScope
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import pl.dmq.peering.feature.pairing.FakeQrSource

class ConnectManageTest {
    @Test
    fun aChosenRouteReachesTheWiringWithTheComputerItWasChosenFor() = runTest(UnconfinedTestDispatcher()) {
        val chosen = mutableListOf<Pair<String, ConnectVia>>()
        val presenter = ConnectPresenter(
            hosts = FakeHostSource(),
            presence = FakePresenceSource(),
            qrSource = FakeQrSource(),
            onConnect = { _ -> },
            onConnectVia = { id, via -> chosen += id to via },
            onPair = { _ -> },
            onConnectAddress = { _ -> },
            scope = backgroundScope,
        )

        presenter.connectVia("B1", ConnectVia.Relay)

        assertEquals(listOf("B1" to ConnectVia.Relay), chosen)
    }

    @Test
    fun aNewNameIsTrimmedBeforeItIsStored() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource()
        val presenter = presenter(hosts, backgroundScope)

        presenter.rename("B1", "  Studio  ")

        assertEquals(listOf("B1" to "Studio"), hosts.renamed)
    }

    @Test
    fun dismissingTheMessageClearsIt() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource(paired = listOf(PairedHost("B1", "Studio")), forgetSucceeds = false)
        val presenter = presenter(hosts, backgroundScope)
        presenter.requestForget("B1")
        presenter.confirmForget()
        assertEquals(ConnectMessage.ForgetFailed, presenter.state.value.message)

        presenter.dismissMessage()

        assertNull(presenter.state.value.message)
    }

    private fun presenter(hosts: FakeHostSource, scope: CoroutineScope) = ConnectPresenter(
        hosts = hosts,
        presence = FakePresenceSource(),
        qrSource = FakeQrSource(),
        onConnect = { _ -> },
        onPair = { _ -> },
        onConnectAddress = { _ -> },
        scope = scope,
    )
}
