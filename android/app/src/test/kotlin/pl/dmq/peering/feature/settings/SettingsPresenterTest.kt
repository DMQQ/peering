package pl.dmq.peering.feature.settings

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsPresenterTest {
    private val alpha = TrustedHost("A", "Alpha")
    private val bravo = TrustedHost("B", null)

    private fun presenter(
        trusted: InMemoryTrustedHostStore = InMemoryTrustedHostStore(listOf(alpha, bravo)),
        identity: FakeIdentityReset = FakeIdentityReset(),
        settings: InMemorySettingsStore = InMemorySettingsStore(),
        scope: CoroutineScope,
    ) = SettingsPresenter(trusted, identity, settings, appVersion = "0.1.0", scope = scope)

    @Test
    fun forgetAsksFirstAndRemovesTheHostOnConfirm() = runTest(UnconfinedTestDispatcher()) {
        val trusted = InMemoryTrustedHostStore(listOf(alpha, bravo))
        val presenter = presenter(trusted = trusted, scope = backgroundScope)

        presenter.requestForget("A")
        assertEquals(alpha, presenter.state.value.forgetTarget)
        assertEquals(emptyList<String>(), trusted.forgotten)

        presenter.confirmForget()

        assertEquals(listOf("A"), trusted.forgotten)
        assertNull(presenter.state.value.forgetTarget)
        assertEquals(listOf(bravo), presenter.state.value.trustedHosts)
        assertNull(presenter.state.value.message)
    }

    @Test
    fun cancellingForgetKeepsTheHost() = runTest(UnconfinedTestDispatcher()) {
        val trusted = InMemoryTrustedHostStore(listOf(alpha))
        val presenter = presenter(trusted = trusted, scope = backgroundScope)

        presenter.requestForget("A")
        presenter.cancelForget()
        presenter.confirmForget()

        assertEquals(emptyList<String>(), trusted.forgotten)
        assertEquals(listOf(alpha), presenter.state.value.trustedHosts)
    }

    @Test
    fun forgetOfAHostNotTrustedIsIgnored() = runTest(UnconfinedTestDispatcher()) {
        val trusted = InMemoryTrustedHostStore(listOf(alpha))
        val presenter = presenter(trusted = trusted, scope = backgroundScope)

        presenter.requestForget("Z")
        presenter.confirmForget()

        assertEquals(emptyList<String>(), trusted.forgotten)
        assertNull(presenter.state.value.forgetTarget)
    }

    @Test
    fun aFailedForgetKeepsTheHostAndSaysSo() = runTest(UnconfinedTestDispatcher()) {
        val trusted = InMemoryTrustedHostStore(listOf(alpha), forgetSucceeds = false)
        val presenter = presenter(trusted = trusted, scope = backgroundScope)

        presenter.requestForget("A")
        presenter.confirmForget()

        assertEquals(SettingsMessage.ForgetFailed, presenter.state.value.message)
        assertEquals(listOf(alpha), presenter.state.value.trustedHosts)
    }

    @Test
    fun identityResetOnlyHappensAfterAConfirmedRequest() = runTest(UnconfinedTestDispatcher()) {
        val identity = FakeIdentityReset()
        val presenter = presenter(identity = identity, scope = backgroundScope)

        presenter.confirmIdentityReset()
        assertEquals(0, identity.resets)

        presenter.requestIdentityReset()
        assertTrue(presenter.state.value.identityResetPending)
        presenter.cancelIdentityReset()
        presenter.confirmIdentityReset()

        assertEquals(0, identity.resets)
        assertFalse(presenter.state.value.identityResetPending)
    }

    @Test
    fun confirmedIdentityResetRunsOnceAndReportsDone() = runTest(UnconfinedTestDispatcher()) {
        val identity = FakeIdentityReset()
        val presenter = presenter(identity = identity, scope = backgroundScope)

        presenter.requestIdentityReset()
        presenter.confirmIdentityReset()
        presenter.confirmIdentityReset()

        assertEquals(1, identity.resets)
        assertFalse(presenter.state.value.identityResetPending)
        assertEquals(SettingsMessage.ResetDone, presenter.state.value.message)
    }

    @Test
    fun aFailedIdentityResetSaysSo() = runTest(UnconfinedTestDispatcher()) {
        val presenter = presenter(identity = FakeIdentityReset(succeeds = false), scope = backgroundScope)

        presenter.requestIdentityReset()
        presenter.confirmIdentityReset()

        assertEquals(SettingsMessage.ResetFailed, presenter.state.value.message)
    }

    @Test
    fun streamQualityIsSavedAndShownAsChosen() = runTest(UnconfinedTestDispatcher()) {
        val settings = InMemorySettingsStore()
        val presenter = presenter(settings = settings, scope = backgroundScope)

        presenter.chooseStreamQuality(StreamQuality.High)

        assertEquals(listOf(StreamQuality.High), settings.saved)
        assertEquals(StreamQuality.High, presenter.state.value.streamQuality)
        assertNull(presenter.state.value.message)
    }

    @Test
    fun aQualityThatDidNotSaveIsNotShownAsChosen() = runTest(UnconfinedTestDispatcher()) {
        val settings = InMemorySettingsStore(initial = StreamQuality.Low, saveSucceeds = false)
        val presenter = presenter(settings = settings, scope = backgroundScope)

        presenter.chooseStreamQuality(StreamQuality.High)

        assertEquals(StreamQuality.Low, presenter.state.value.streamQuality)
        assertEquals(SettingsMessage.QualitySaveFailed, presenter.state.value.message)
    }

    @Test
    fun aboutShowsTheInjectedVersion() = runTest(UnconfinedTestDispatcher()) {
        val presenter = presenter(scope = backgroundScope)

        assertEquals("0.1.0", presenter.state.value.appVersion)
    }
}
