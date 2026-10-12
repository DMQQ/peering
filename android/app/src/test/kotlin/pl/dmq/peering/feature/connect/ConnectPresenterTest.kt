package pl.dmq.peering.feature.connect

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.feature.pairing.FakeQrSource

class ConnectPresenterTest {
    private fun presenterFor(
        hosts: FakeHostSource,
        presence: FakePresenceSource,
        onConnect: (String) -> Unit = {},
        onPair: (String) -> Unit = {},
        scope: CoroutineScope,
    ) = ConnectPresenter(
        hosts = hosts,
        presence = presence,
        qrSource = FakeQrSource(),
        onConnect = onConnect,
        onPair = onPair,
        scope = scope,
    )

    @Test
    fun pairedHostsAreListedInStatusOrderWithPresenceApplied() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource(
            paired = listOf(PairedHost("A", "Alpha"), PairedHost("B", "Bravo"), PairedHost("C", "Charlie")),
        )
        val presence = FakePresenceSource(online = setOf("C"), connected = "B")

        val presenter = presenterFor(hosts, presence, scope = backgroundScope)

        assertEquals(listOf("B", "C", "A"), presenter.state.value.listing.paired.map { it.id })
        assertEquals(HostStatus.Connected, presenter.state.value.listing.paired.first().status)
    }

    @Test
    fun presenceChangesReachTheListWithoutReloading() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource(paired = listOf(PairedHost("A", "Alpha")))
        val presence = FakePresenceSource()
        val presenter = presenterFor(hosts, presence, scope = backgroundScope)
        assertEquals(HostStatus.Unknown, presenter.state.value.listing.paired.single().status)

        presence.online.value = setOf("A")

        assertEquals(HostStatus.Online, presenter.state.value.listing.paired.single().status)
    }

    @Test
    fun nearbyHostsAppearAsTheyAreFound() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource()
        val presenter = presenterFor(hosts, FakePresenceSource(), scope = backgroundScope)
        assertEquals(emptyList<HostRow>(), presenter.state.value.listing.nearby)

        hosts.nearby.value = listOf(nearbyHost("N1", name = "Desk"))

        assertEquals(listOf("N1"), presenter.state.value.listing.nearby.map { it.id })
    }

    @Test
    fun forgetAsksBeforeRemovingAndRemovesOnConfirm() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource(paired = listOf(PairedHost("A", "Alpha")))
        val presenter = presenterFor(hosts, FakePresenceSource(), scope = backgroundScope)

        presenter.requestForget("A")
        assertEquals("A", presenter.state.value.forgetTarget?.id)
        assertEquals(emptyList<String>(), hosts.forgotten)

        presenter.confirmForget()

        assertEquals(listOf("A"), hosts.forgotten)
        assertNull(presenter.state.value.forgetTarget)
        assertNull(presenter.state.value.message)
        assertEquals(emptyList<HostRow>(), presenter.state.value.listing.paired)
    }

    @Test
    fun cancellingForgetKeepsTheHost() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource(paired = listOf(PairedHost("A", "Alpha")))
        val presenter = presenterFor(hosts, FakePresenceSource(), scope = backgroundScope)

        presenter.requestForget("A")
        presenter.cancelForget()
        presenter.confirmForget()

        assertEquals(emptyList<String>(), hosts.forgotten)
        assertEquals(listOf("A"), presenter.state.value.listing.paired.map { it.id })
    }

    @Test
    fun forgetOfANonPairedHostIsIgnored() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource(nearby = listOf(nearbyHost("N1")))
        val presenter = presenterFor(hosts, FakePresenceSource(), scope = backgroundScope)

        presenter.requestForget("N1")
        presenter.confirmForget()

        assertNull(presenter.state.value.forgetTarget)
        assertEquals(emptyList<String>(), hosts.forgotten)
    }

    @Test
    fun aFailedForgetKeepsTheHostAndSaysSo() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource(paired = listOf(PairedHost("A", "Alpha")), forgetSucceeds = false)
        val presenter = presenterFor(hosts, FakePresenceSource(), scope = backgroundScope)

        presenter.requestForget("A")
        presenter.confirmForget()

        assertEquals(ConnectMessage.ForgetFailed, presenter.state.value.message)
        assertEquals(listOf("A"), presenter.state.value.listing.paired.map { it.id })
    }

    @Test
    fun connectAndPairReportTheHostIdToTheWiring() = runTest(UnconfinedTestDispatcher()) {
        val connected = mutableListOf<String>()
        val paired = mutableListOf<String>()
        val presenter = presenterFor(
            FakeHostSource(nearby = listOf(nearbyHost("N1"))),
            FakePresenceSource(),
            onConnect = { connected += it },
            onPair = { paired += it },
            scope = backgroundScope,
        )

        presenter.connect("A")
        presenter.pair("N1")

        assertEquals(listOf("A"), connected)
        assertEquals(listOf("N1"), paired)
    }

    @Test
    fun searchAgainRestartsDiscovery() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource()
        val presenter = presenterFor(hosts, FakePresenceSource(), scope = backgroundScope)

        presenter.searchAgain()

        assertEquals(1, hosts.searchRestarts)
    }
}
