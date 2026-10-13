package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.KeyDown
import pl.dmq.peering.wire.KeyUp
import pl.dmq.peering.wire.Modifiers
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.TextInput

class KeyboardPresenterTest {
    private val sink = RecordingCommandSink()
    private val presenter = KeyboardPresenter(sink)

    @Test
    fun `committed soft keyboard text is typed as text`() {
        presenter.onSoftKeyboardText("hello")

        assertEquals(listOf<RemoteCommand>(TextInput("hello")), sink.sent)
    }

    @Test
    fun `dictated words follow a word on the line after one space`() {
        presenter.onSoftKeyboardText("ls")
        presenter.onDictated(" -la ")

        assertEquals(listOf<RemoteCommand>(TextInput("ls"), TextInput(" -la")), sink.sent)
    }

    @Test
    fun `dictated words on an empty line are typed as heard and silence types nothing`() {
        presenter.onDictated("hello")
        presenter.onDictated("   ")

        assertEquals(listOf<RemoteCommand>(TextInput("hello")), sink.sent)
    }

    @Test
    fun `an editing key is pressed and released by its Mac keycode`() {
        presenter.onEditingKey(EditingKey.ESCAPE)

        assertEquals(listOf<RemoteCommand>(KeyDown(53, Modifiers(0)), KeyUp(53, Modifiers(0))), sink.sent)
    }

    @Test
    fun `a printable hardware key is typed as text on press only`() {
        assertTrue(presenter.onKey(KeyInput(androidKeyCode = 29, unicodeChar = 'a'.code, metaState = 0, isDown = true)))
        assertTrue(presenter.onKey(KeyInput(androidKeyCode = 29, unicodeChar = 'a'.code, metaState = 0, isDown = false)))

        assertEquals(listOf<RemoteCommand>(TextInput("a")), sink.sent)
    }

    @Test
    fun `control with a letter is a key press that carries the control modifier`() {
        presenter.onKey(KeyInput(androidKeyCode = 31, unicodeChar = 0, metaState = CTRL_ON, isDown = true))
        presenter.onKey(KeyInput(androidKeyCode = 31, unicodeChar = 0, metaState = CTRL_ON, isDown = false))

        assertEquals(
            listOf<RemoteCommand>(KeyDown(8, Modifiers(Modifiers.CONTROL)), KeyUp(8, Modifiers(Modifiers.CONTROL))),
            sink.sent,
        )
    }

    @Test
    fun `a key with no macOS equivalent is not handled and sends nothing`() {
        val handled = presenter.onKey(KeyInput(androidKeyCode = KEYCODE_BACK, unicodeChar = 0, metaState = 0, isDown = true))

        assertFalse(handled)
        assertTrue(sink.sent.isEmpty())
    }

    @Test
    fun `a latched command turns the next typed letter into a command key press`() {
        presenter.onModifierTap(StickyModifier.COMMAND, timeMs = 0)
        sink.sent.clear()

        presenter.onSoftKeyboardText("c")

        assertEquals(
            listOf<RemoteCommand>(
                KeyDown(8, Modifiers(Modifiers.COMMAND)),
                KeyUp(8, Modifiers(Modifiers.COMMAND)),
                KeyUp(55, Modifiers(0)),
            ),
            sink.sent,
        )
        assertEquals(ModifierLatch.OFF, presenter.latches.value.getValue(StickyModifier.COMMAND))
    }

    @Test
    fun `a latched shift types a capital letter through its key`() {
        presenter.onModifierTap(StickyModifier.SHIFT, timeMs = 0)
        sink.sent.clear()

        presenter.onSoftKeyboardText("a")

        assertEquals(KeyDown(0, Modifiers(Modifiers.SHIFT)), sink.sent.first())
    }

    @Test
    fun `a latched modifier is spent on a character with no key and the character still types`() {
        presenter.onModifierTap(StickyModifier.OPTION, timeMs = 0)
        sink.sent.clear()

        presenter.onSoftKeyboardText("€")

        assertEquals(TextInput("€"), sink.sent.first())
        assertEquals(ModifierLatch.OFF, presenter.latches.value.getValue(StickyModifier.OPTION))
    }

    @Test
    fun `a soft keyboard delete is a Backspace press`() {
        presenter.onSoftKeyboardDelete()

        assertEquals(listOf<RemoteCommand>(KeyDown(51, Modifiers(0)), KeyUp(51, Modifiers(0))), sink.sent)
    }

    @Test
    fun `a function key is pressed with the latched modifiers and then the latch is spent`() {
        presenter.onModifierTap(StickyModifier.SHIFT, timeMs = 0)
        sink.sent.clear()

        presenter.onFunctionKey(FunctionKey.F5)

        assertEquals(KeyDown(96, Modifiers(Modifiers.SHIFT)), sink.sent[0])
        assertEquals(KeyUp(96, Modifiers(Modifiers.SHIFT)), sink.sent[1])
        assertEquals(KeyUp(56, Modifiers(0)), sink.sent[2])
    }

    @Test
    fun `a locked modifier stays held across keys`() {
        presenter.onModifierTap(StickyModifier.CONTROL, timeMs = 0)
        presenter.onModifierTap(StickyModifier.CONTROL, timeMs = 100)
        sink.sent.clear()

        presenter.onSoftKeyboardDelete()
        presenter.onSoftKeyboardDelete()

        assertEquals(ModifierLatch.LOCKED, presenter.latches.value.getValue(StickyModifier.CONTROL))
        val control = Modifiers(Modifiers.CONTROL)
        assertEquals(
            listOf<RemoteCommand>(KeyDown(51, control), KeyUp(51, control), KeyDown(51, control), KeyUp(51, control)),
            sink.sent,
        )
    }

    @Test
    fun `the typed preview follows typing, deleting and Enter`() {
        presenter.onSoftKeyboardText("helo")
        presenter.onSoftKeyboardDelete()
        presenter.onSoftKeyboardText("lo")
        assertEquals("hello", presenter.typedPreview.value)

        presenter.pressEnter()

        assertEquals("", presenter.typedPreview.value)
    }

    @Test
    fun `keycode mode presses keys so a shortcut can follow and sends other characters as text`() {
        val keycode = KeyboardPresenter(sink) { KeyboardMode.KEYCODE }

        keycode.onSoftKeyboardText("aBé")

        val none = Modifiers(0)
        assertEquals(
            listOf<RemoteCommand>(
                KeyDown(0, none), KeyUp(0, none),
                KeyDown(11, Modifiers(Modifiers.SHIFT)), KeyUp(11, Modifiers(Modifiers.SHIFT)),
                TextInput("é"),
            ),
            sink.sent,
        )
    }

    @Test
    fun `a dock key carries what is latched and releases it after`() {
        presenter.onModifierTap(StickyModifier.COMMAND, timeMs = 0)
        sink.sent.clear()

        presenter.sendKey(123)

        val command = Modifiers(Modifiers.COMMAND)
        assertEquals(KeyDown(123, command), sink.sent[0])
        assertEquals(KeyUp(123, command), sink.sent[1])
        assertEquals(ModifierLatch.OFF, presenter.latches.value.getValue(StickyModifier.COMMAND))
    }

    @Test
    fun `a chord sent with its own modifiers is not latched`() {
        presenter.sendKey(8, Modifiers.COMMAND)

        assertEquals(listOf<RemoteCommand>(KeyDown(8, Modifiers(Modifiers.COMMAND)), KeyUp(8, Modifiers(Modifiers.COMMAND))), sink.sent)
    }

    private companion object {
        const val CTRL_ON = 0x1000L
        const val KEYCODE_BACK = 4
    }
}
