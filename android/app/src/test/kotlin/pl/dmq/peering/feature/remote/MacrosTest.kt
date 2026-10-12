package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.Modifiers

class MacrosTest {
    @Test
    fun theBuiltInSetHasTheSeventeenDefaults() {
        assertEquals(17, Macros.defaults.size)
        assertEquals(Macros.defaults.size, Macros.defaults.map { it.id }.toSet().size)
    }

    @Test
    fun theAutomaticTitleListsModifiersInTheMacsOrderThenTheKey() {
        val key = MacroKeys.popular.single { it.id == "p" }

        val title = Macros.autoTitle(key, Modifiers.COMMAND or Modifiers.SHIFT or Modifiers.OPTION)

        assertEquals("⌥⇧⌘P", title)
    }

    @Test
    fun everyLetterKeyHasItsMacKeyCode() {
        assertEquals(0, MacroKeys.popular.single { it.id == "a" }.keyCode)
        assertEquals(6, MacroKeys.popular.single { it.id == "z" }.keyCode)
        assertTrue(MacroKeys.popular.any { it.id == "f12" && it.keyCode == 111 })
    }

    @Test
    fun storedMacrosComeBackAsTheyWentIn() {
        val macros = listOf(Macro("a", "⌘K", 40, Modifiers.COMMAND), Macro("b", "Save all", 1, Modifiers.COMMAND or Modifiers.OPTION))

        assertEquals(macros, MacroCodec.decode(MacroCodec.encode(macros)))
    }

    @Test
    fun aDamagedLineCostsOnlyItself() {
        val text = "broken\n" + MacroCodec.encode(listOf(Macro("a", "⌘K", 40, Modifiers.COMMAND)))

        assertEquals(1, MacroCodec.decode(text).size)
    }
}
