package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KeyMapTest {
    private val keymap: JsonObject = VectorFiles.load("keymap.json").jsonObject

    private val keyA = 29
    private val keyC = 31
    private val keyEnter = 66
    private val keyTab = 61
    private val keySpace = 62
    private val keyInsert = 124
    private val metaShift = 0x1L
    private val metaAlt = 0x2L
    private val metaCtrl = 0x1000L
    private val metaMeta = 0x10000L

    @Test
    fun everyAndroidEntryMatchesTheVector() {
        val android = keymap.getValue("android").jsonObject
        for ((androidCode, macCode) in android) {
            assertEquals("android $androidCode", macCode.jsonPrimitive.long.toInt(), macKeyCode(androidCode.toInt()))
        }
    }

    @Test
    fun anUnmappedAndroidCodeHasNoMacCode() {
        assertNull(macKeyCode(keyInsert))
        assertNull(macKeyCode(-1))
    }

    @Test
    fun modifierBitsMatchTheVector() {
        val bits = keymap.getValue("modifierBits").jsonObject
        assertEquals(1L shl bits.getValue("shift").jsonPrimitive.long.toInt(), Modifiers.SHIFT)
        assertEquals(1L shl bits.getValue("control").jsonPrimitive.long.toInt(), Modifiers.CONTROL)
        assertEquals(1L shl bits.getValue("option").jsonPrimitive.long.toInt(), Modifiers.OPTION)
        assertEquals(1L shl bits.getValue("command").jsonPrimitive.long.toInt(), Modifiers.COMMAND)
        assertEquals(1L shl bits.getValue("topRowAction").jsonPrimitive.long.toInt(), Modifiers.TOP_ROW_ACTION)
    }

    @Test
    fun aPlainPrintableCharacterIsText() {
        assertEquals(KeyRoute.Text('a'.code), routeKey('a'.code, keyA, 0L))
    }

    @Test
    fun aShiftedPrintableCharacterIsStillText() {
        assertEquals(KeyRoute.Text('A'.code), routeKey('A'.code, keyA, metaShift))
    }

    @Test
    fun aSpaceIsText() {
        assertEquals(KeyRoute.Text(' '.code), routeKey(' '.code, keySpace, 0L))
    }

    @Test
    fun aPrintableCharacterWithControlIsAKeyWithControl() {
        assertEquals(KeyRoute.Key(8, Modifiers.CONTROL), routeKey('c'.code, keyC, metaCtrl))
    }

    @Test
    fun aPrintableCharacterWithAltIsAKeyWithOption() {
        assertEquals(KeyRoute.Key(0, Modifiers.OPTION), routeKey('a'.code, keyA, metaAlt))
    }

    @Test
    fun aPrintableCharacterWithMetaIsAKeyWithCommand() {
        assertEquals(KeyRoute.Key(8, Modifiers.COMMAND), routeKey('c'.code, keyC, metaMeta))
    }

    @Test
    fun enterIsAKeyEvenWhenItHasAControlCharacter() {
        assertEquals(KeyRoute.Key(36, 0L), routeKey('\n'.code, keyEnter, 0L))
    }

    @Test
    fun shiftTabIsAKeyWithShift() {
        assertEquals(KeyRoute.Key(48, Modifiers.SHIFT), routeKey(0, keyTab, metaShift))
    }

    @Test
    fun unknownMetaStateCountsAsNoModifiers() {
        assertEquals(KeyRoute.Text('a'.code), routeKey('a'.code, keyA, null))
    }

    @Test
    fun aKeyWithNoMacEquivalentAndNoCharacterIsIgnored() {
        assertEquals(KeyRoute.Ignored, routeKey(0, keyInsert, 0L))
    }
}
