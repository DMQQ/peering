package pl.dmq.peering.feature.connect

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.feature.pairing.FakeQrSource

class NearbyPhaseTest {
    @Test
    fun withoutALocalNetworkNothingElseMatters() {
        assertEquals(NearbyPhase.NoNetwork, NearbyPhase.of(onLocalNetwork = false, nearbyCount = 3, searching = true))
    }

    @Test
    fun foundHostsBeatSearching() {
        assertEquals(NearbyPhase.Found, NearbyPhase.of(onLocalNetwork = true, nearbyCount = 1, searching = true))
    }

    @Test
    fun searchingGivesWayToNoneFound() {
        assertEquals(NearbyPhase.Searching, NearbyPhase.of(onLocalNetwork = true, nearbyCount = 0, searching = true))
        assertEquals(NearbyPhase.NoneFound, NearbyPhase.of(onLocalNetwork = true, nearbyCount = 0, searching = false))
    }

    private class FakeNetwork(initial: Boolean) : NetworkSource {
        val onNetwork = MutableStateFlow(initial)
        override fun onLocalNetwork(): Flow<Boolean> = onNetwork
    }

    private fun TestScope.presenter(network: NetworkSource, hosts: FakeHostSource = FakeHostSource()) = ConnectPresenter(
        hosts = hosts,
        presence = FakePresenceSource(),
        qrSource = FakeQrSource(),
        onConnect = {},
        onPair = {},
        scope = backgroundScope,
        network = network,
        searchWindowMillis = 1_000,
    )

    @Test
    fun theScreenSearchesForTheWindowThenReportsNoneFound() = runTest(UnconfinedTestDispatcher()) {
        val presenter = presenter(FakeNetwork(true))
        assertEquals(NearbyPhase.Searching, presenter.state.value.nearbyPhase)

        advanceTimeBy(1_001)

        assertEquals(NearbyPhase.NoneFound, presenter.state.value.nearbyPhase)
    }

    @Test
    fun searchingAgainStartsANewWindow() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource()
        val presenter = presenter(FakeNetwork(true), hosts)
        advanceTimeBy(1_001)

        presenter.searchAgain()

        assertEquals(NearbyPhase.Searching, presenter.state.value.nearbyPhase)
        assertEquals(1, hosts.searchRestarts)
    }

    @Test
    fun leavingWifiShowsNoNetworkAndComingBackResumesTheSearchState() = runTest(UnconfinedTestDispatcher()) {
        val network = FakeNetwork(false)
        val presenter = presenter(network)
        assertEquals(NearbyPhase.NoNetwork, presenter.state.value.nearbyPhase)

        network.onNetwork.value = true

        assertEquals(NearbyPhase.Searching, presenter.state.value.nearbyPhase)
    }

    @Test
    fun aHostFoundAtAnyPointShowsAsFound() = runTest(UnconfinedTestDispatcher()) {
        val hosts = FakeHostSource()
        val presenter = presenter(FakeNetwork(true), hosts)

        hosts.nearby.value = listOf(nearbyHost("N1"))

        assertEquals(NearbyPhase.Found, presenter.state.value.nearbyPhase)
    }
}
