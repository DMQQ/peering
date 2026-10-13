package pl.dmq.peering.feature.terminal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalKeyboardTest {
    private val sent = mutableListOf<ByteArray>()
    private val keyboard = TerminalKeyboard { sent += it }

    @Test
    fun extraKeysSendTheirSequences() {
        keyboard.press(ExtraKey.ESCAPE)
        keyboard.press(ExtraKey.TAB)
        keyboard.press(ExtraKey.UP)
        keyboard.press(ExtraKey.LEFT)
        keyboard.press(ExtraKey.PIPE)
        keyboard.press(ExtraKey.TILDE)
        assertEquals(listOf("\u001B", "\t", "\u001B[A", "\u001B[D", "|", "~"), sent.map { String(it) })
    }

    @Test
    fun ctrlTurnsTheNextLetterIntoItsControlCodeThenReleases() {
        keyboard.toggleCtrl()
        assertTrue(keyboard.ctrl)
        keyboard.type("c")
        keyboard.type("c")
        assertArrayEquals(byteArrayOf(3), sent[0])
        assertArrayEquals("c".toByteArray(), sent[1])
        assertFalse(keyboard.ctrl)
    }

    @Test
    fun altPrefixesEscapeAndReleases() {
        keyboard.toggleAlt()
        keyboard.type("b")
        assertArrayEquals(byteArrayOf(0x1B, 'b'.code.toByte()), sent.single())
        assertFalse(keyboard.alt)
    }

    @Test
    fun altWithAnArrowPrefixesEscapeButNotWithEscapeItself() {
        assertArrayEquals(byteArrayOf(0x1B, 0x1B, '['.code.toByte(), 'A'.code.toByte()), TerminalKeys.bytes(ExtraKey.UP, alt = true))
        assertArrayEquals(byteArrayOf(0x1B), TerminalKeys.bytes(ExtraKey.ESCAPE, alt = true))
    }

    @Test
    fun ctrlOnlyTouchesTheFirstCharacterOfARun() {
        assertArrayEquals(byteArrayOf(1, 'b'.code.toByte(), 'c'.code.toByte()), TerminalKeys.bytes("abc", ctrl = true))
    }

    @Test
    fun ctrlOnAKeyWithNoControlCodeTypesItPlain() {
        assertArrayEquals("5".toByteArray(), TerminalKeys.bytes("5", ctrl = true))
    }

    @Test
    fun newlinesBecomeCarriageReturns() {
        assertArrayEquals("a\rb\r".toByteArray(), TerminalKeys.bytes("a\nb\r\n"))
    }

    @Test
    fun backspaceSendsDeleteAndEnterSendsReturn() {
        keyboard.backspace()
        keyboard.enter()
        assertArrayEquals(byteArrayOf(0x7F), sent[0])
        assertArrayEquals(byteArrayOf(0x0D), sent[1])
    }

    @Test
    fun pasteIgnoresAHeldCtrl() {
        keyboard.toggleCtrl()
        keyboard.paste("ls")
        assertArrayEquals("ls".toByteArray(), sent.single())
        assertTrue(keyboard.ctrl)
    }

    @Test
    fun anEmptyTypedRunSendsNothingAndKeepsTheLatch() {
        keyboard.toggleCtrl()
        keyboard.type("")
        assertTrue(sent.isEmpty())
        assertTrue(keyboard.ctrl)
    }

    @Test
    fun theAstralCharacterStaysWhole() {
        assertArrayEquals("😀x".toByteArray(), TerminalKeys.bytes("😀x"))
    }
}
