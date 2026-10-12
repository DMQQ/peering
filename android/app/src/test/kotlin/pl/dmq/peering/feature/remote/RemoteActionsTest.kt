package pl.dmq.peering.feature.remote

import android.view.Surface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import pl.dmq.peering.session.clipboard.ClipboardEntry
import pl.dmq.peering.session.clipboard.ClipboardPush
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.feature.settings.InMemoryDevicePreferences
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.session.controller.QualityChoice
import pl.dmq.peering.wire.JoystickMove
import pl.dmq.peering.wire.KeyDown
import pl.dmq.peering.wire.KeyUp
import pl.dmq.peering.wire.LockScreen
import pl.dmq.peering.wire.Modifiers
import pl.dmq.peering.wire.PushClipboard
import pl.dmq.peering.wire.QualityTier
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.Scroll
import pl.dmq.peering.wire.SetPrivacyMode

class RemoteActionsTest {
    private val sink = RecordingCommandSink()
    private val prefs = InMemoryDevicePreferences()

    private val model = object : RemoteModel {
        override val statusPillMemory = StatusPillMemory()
        override val state: StateFlow<RemoteUiState> = MutableStateFlow(RemoteUiState.INITIAL)
        override val commands: CommandSink = sink
        override val surface = object : SurfaceListener {
            override fun onSurfaceAvailable(surface: Surface) = Unit
            override fun onSurfaceSizeChanged(width: Int, height: Int) = Unit
            override fun onSurfaceGone() = Unit
        }
        override val quality = object : QualityPort {
            override val stored = emptyFlow<StreamQuality>()
            override val ceiling: StateFlow<QualityTier> = MutableStateFlow(QualityTier.HIGH)
            override fun saveDefault(quality: StreamQuality) = true
            override fun apply(choice: QualityChoice) = true
        }
        override val prefs = this@RemoteActionsTest.prefs
        override val macros = object : MacroStore {
            override val custom = MutableStateFlow(emptyList<Macro>())
            override fun add(macro: Macro) = true
            override fun remove(id: String) = true
        }
        override val clipboard = object : ClipboardPort {
            override val history = MutableStateFlow(emptyList<ClipboardEntry>())
            override fun sendImage(png: ByteArray) = ClipboardPush.Sent
            override fun remove(id: Long) = Unit
            override fun clear() = Unit
        }
        override fun onHubEntry(entry: HubEntry) = Unit
        override fun onStepAway() = Unit
        override fun onRetryPicture() = Unit
        override fun onRelayUpgradeRequested() = Unit
    }

    private fun actions(scope: CoroutineScope): RemoteActions {
        val canvas = RemoteCanvasPresenter(sink, InputMode.TRACKPAD)
        return RemoteActions(model, sink, SessionScreenState(), canvas, KeyboardPresenter(sink), { prefs.prefs.value }, { 1000.0 to 600.0 }, scope)
    }

    @Test
    fun theWheelScrollsTheComputerByTheNotchSize() = runTest(UnconfinedTestDispatcher()) {
        actions(backgroundScope).wheelNotch(2)

        assertEquals(listOf<RemoteCommand>(Scroll(0.0, 2 * ScrollNotch.PIXELS)), sink.sent)
    }

    @Test
    fun theModeButtonSwapsBetweenObservingAndTheControlModeLastUsed() = runTest(UnconfinedTestDispatcher()) {
        val actions = actions(backgroundScope)

        actions.toggleMode()
        assertEquals(InputMode.OBSERVE, prefs.prefs.value.interaction)

        actions.toggleMode()
        assertEquals(InputMode.TRACKPAD, prefs.prefs.value.interaction)
    }

    @Test
    fun theJoystickMovesByItsTravelTimesTheChosenSpeed() = runTest(UnconfinedTestDispatcher()) {
        val actions = actions(backgroundScope)

        actions.stepSpeed()
        actions.joystickMove(10.0, -4.0)

        assertEquals(listOf<RemoteCommand>(JoystickMove(15.0, -6.0)), sink.sent)
    }

    @Test
    fun lockAndDarkenSendTheirCommands() = runTest(UnconfinedTestDispatcher()) {
        val actions = actions(backgroundScope)

        actions.lock()
        actions.toggleDark()
        actions.toggleDark()

        assertEquals(listOf<RemoteCommand>(LockScreen, SetPrivacyMode(true), SetPrivacyMode(false)), sink.sent)
    }

    @Test
    fun pasteOnTheComputerPushesTheTextThenPressesCommandV() = runTest(UnconfinedTestDispatcher()) {
        actions(backgroundScope).paste("hello")

        val command = Modifiers(Modifiers.COMMAND)
        assertEquals(listOf<RemoteCommand>(PushClipboard("hello"), KeyDown(9, command), KeyUp(9, command)), sink.sent)
    }

    @Test
    fun theFillChoiceIsStoredInTheSettings() = runTest(UnconfinedTestDispatcher()) {
        val actions = actions(backgroundScope)

        actions.toggleFill()

        assertEquals(true, prefs.prefs.value.fillsScreen)
    }
}
