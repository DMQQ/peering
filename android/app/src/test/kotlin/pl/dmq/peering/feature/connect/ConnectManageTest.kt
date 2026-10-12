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
    fun aTrustedComputerIsConnectedToInsteadOfPaired() = runTest(UnconfinedTestDispatcher()) {
        val connected = mutableListOf<String>()
        val paired = mutableListOf<String>()
        val presenter = ConnectPresenter(
            hosts = FakeHostSource(paired = listOf(PairedHost("B1", "Studio"))),
            presence = FakePresenceSource(),
            qrSource = FakeQrSource(),
            onConnect = { connected += it },
            onPair = { paired += it },
            onConnectAddress = { _ -> },
            scope = backgroundScope,
        )

        presenter.pair("B1")
        presenter.pair("N1")

        assertEquals(listOf("B1"), connected)
        assertEquals(listOf("N1"), paired)
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
