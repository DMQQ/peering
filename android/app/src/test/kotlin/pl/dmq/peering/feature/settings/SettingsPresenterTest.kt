package pl.dmq.peering.feature.settings

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.KeyboardMode

class SettingsPresenterTest {
    private val alpha = TrustedHost("A", "Alpha")
    private val bravo = TrustedHost("B", null)

    private fun presenter(
        trusted: InMemoryTrustedHostStore = InMemoryTrustedHostStore(listOf(alpha, bravo)),
        settings: InMemorySettingsStore = InMemorySettingsStore(),
        device: InMemoryDevicePreferences = InMemoryDevicePreferences(),
        scope: CoroutineScope,
    ) = SettingsPresenter(trusted, settings, device, deviceId = "device-1", paidRelay = MutableStateFlow(false), appVersion = "0.1.0", scope = scope)

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

    @Test
    fun theDeviceNameIsTrimmedAndSaved() = runTest(UnconfinedTestDispatcher()) {
        val device = InMemoryDevicePreferences()
        val presenter = presenter(device = device, scope = backgroundScope)

        presenter.setDeviceName("  Damian's phone ")

        assertEquals("Damian's phone", presenter.state.value.prefs.deviceName)
    }

    @Test
    fun aBlankDeviceNameIsIgnored() = runTest(UnconfinedTestDispatcher()) {
        val presenter = presenter(scope = backgroundScope)

        presenter.setDeviceName("   ")

        assertEquals("Pixel", presenter.state.value.prefs.deviceName)
    }

    @Test
    fun theSessionChoicesAreSavedAsChosen() = runTest(UnconfinedTestDispatcher()) {
        val presenter = presenter(scope = backgroundScope)

        presenter.chooseInteraction(InputMode.OBSERVE)
        presenter.chooseFill(true)
        presenter.chooseKeyboardMode(KeyboardMode.KEYCODE)
        presenter.setHidesPanelAfterSelect(false)
        presenter.setAllowsRelay(false)

        val prefs = presenter.state.value.prefs
        assertEquals(InputMode.OBSERVE, prefs.interaction)
        assertEquals(true, prefs.fillsScreen)
        assertEquals(KeyboardMode.KEYCODE, prefs.keyboardMode)
        assertEquals(false, prefs.hidesPanelAfterSelect)
        assertEquals(false, prefs.allowsRelay)
    }

    @Test
    fun aChoiceThatDidNotSaveIsNotShownAndSaysSo() = runTest(UnconfinedTestDispatcher()) {
        val presenter = presenter(device = InMemoryDevicePreferences(saveSucceeds = false), scope = backgroundScope)

        presenter.setAllowsRelay(false)

        assertEquals(true, presenter.state.value.prefs.allowsRelay)
        assertEquals(SettingsMessage.PreferenceSaveFailed, presenter.state.value.message)
    }
}
