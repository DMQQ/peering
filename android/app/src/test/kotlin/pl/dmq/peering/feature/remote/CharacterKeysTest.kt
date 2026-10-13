package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CharacterKeysTest {
    @Test
    fun `letters of either case share one keycode`() {
        assertEquals(0, macKeyForCharacter('a'.code))
        assertEquals(0, macKeyForCharacter('A'.code))
        assertEquals(6, macKeyForCharacter('z'.code))
    }

    @Test
    fun `digits take their US keyboard keycodes`() {
        assertEquals(29, macKeyForCharacter('0'.code))
        assertEquals(25, macKeyForCharacter('9'.code))
    }

    @Test
    fun `characters without a key here are not mapped`() {
        assertNull(macKeyForCharacter('-'.code))
        assertNull(macKeyForCharacter(0x20AC))
    }
}
