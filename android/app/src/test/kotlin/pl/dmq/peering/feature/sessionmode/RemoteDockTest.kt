package pl.dmq.peering.feature.sessionmode

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.wire.KeyDown
import pl.dmq.peering.wire.KeyUp
import pl.dmq.peering.wire.Modifiers
import pl.dmq.peering.wire.SpaceDirection
import pl.dmq.peering.wire.SpaceDisplay
import pl.dmq.peering.wire.SwitchSpace
import pl.dmq.peering.wire.SwitchToSpace

class RemoteDockTest {
    private class MapStore : KeyValueStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) { values[key] = value }
    }

    private data class App(val bundle: String?, val name: String)

    @Test
    fun favouritesKeepPinnedOrderAndArePerComputer() {
        val store = MapStore()
        val first = ApplicationFavourites(store, "mac-1")
        first.toggle("b")
        first.toggle("a")
        assertEquals(listOf("b", "a"), first.bundleIdentifiers)
        assertTrue("a" in first)
        first.toggle("b")
        assertEquals(listOf("a"), first.bundleIdentifiers)
        assertEquals(emptyList<String>(), ApplicationFavourites(store, "mac-2").bundleIdentifiers)
    }

    @Test
    fun eachAppAppearsOnceInTheFirstSectionThatClaimsIt() {
        val running = listOf(App("safari", "Safari"), App(null, "Helper"), App("notes", "Notes"))
        val installed = listOf(App("notes", "Notes"), App("music", "Music"), App(null, "Odd"), App("mail", "Mail"))
        val sections = ApplicationSections.of(listOf("mail", "gone", "safari"), running, installed) { it.bundle }
        assertEquals(listOf("Mail", "Safari"), sections.favourites.map { it.name })
        assertEquals(listOf("Helper", "Notes"), sections.running.map { it.name })
        assertEquals(listOf("Music"), sections.installed.map { it.name })
    }

    @Test
    fun theLongerAxisDecidesASwipeAndAShortOneIsNone() {
        assertEquals(TrackpadSwipe.LEFT, TrackpadSwipe.of(-60.0, 20.0, 40.0))
        assertEquals(TrackpadSwipe.DOWN, TrackpadSwipe.of(10.0, 50.0, 40.0))
        assertNull(TrackpadSwipe.of(30.0, 30.0, 40.0))
    }

    @Test
    fun swipingLeftGoesToTheNextDesktopAndUpOpensMissionControl() {
        val display = SpaceDisplay(7L, 3, 2, emptyList())
        assertEquals(listOf(SwitchToSpace(7L, 3)), TrackpadSwipe.LEFT.commands(display, desktops = true))
        assertEquals(listOf(SwitchToSpace(7L, 1)), TrackpadSwipe.RIGHT.commands(display, desktops = true))
        val control = Modifiers(Modifiers.CONTROL)
        assertEquals(listOf(KeyDown(126, control), KeyUp(126, control)), TrackpadSwipe.UP.commands(display, desktops = true))
        assertEquals(listOf(KeyDown(125, control), KeyUp(125, control)), TrackpadSwipe.DOWN.commands(display, desktops = true))
    }

    @Test
    fun steppingPastTheLastDesktopSendsNothingAndNoListFallsBackToTheChord() {
        assertNull(DesktopStep.command(SpaceDisplay(1L, 2, 2, emptyList()), 1))
        assertEquals(SwitchSpace(SpaceDirection.LEFT), DesktopStep.command(null, -1))
        assertEquals(SwitchSpace(SpaceDirection.RIGHT), DesktopStep.command(SpaceDisplay(1L, 2, null, emptyList()), 1))
    }

    @Test
    fun anUpsideDownPhoneTurnsTheFingerBack() {
        assertEquals(-3.0 to -4.0, TrackpadOrientation.of(device = 2, screen = 0).intended(3.0, 4.0))
        assertEquals(3.0 to 4.0, TrackpadOrientation.of(device = 1, screen = 1).intended(3.0, 4.0))
        assertEquals(4.0 to -3.0, TrackpadOrientation.of(device = 1, screen = 0).intended(3.0, 4.0))
    }

    @Test
    fun theSensorAngleBecomesCounterclockwiseQuarterTurns() {
        assertEquals(0, TrackpadOrientation.deviceQuarterTurns(10))
        assertEquals(3, TrackpadOrientation.deviceQuarterTurns(90))
        assertEquals(2, TrackpadOrientation.deviceQuarterTurns(185))
        assertEquals(1, TrackpadOrientation.deviceQuarterTurns(270))
        assertEquals(0, TrackpadOrientation.deviceQuarterTurns(350))
        assertNull(TrackpadOrientation.deviceQuarterTurns(-1))
    }

    @Test
    fun theTypingFieldSendsWhatWasAddedOrHowMuchWasDeleted() {
        assertEquals(TypedDiff("lo", 0), TypedDiff.of("hel", "hello"))
        assertEquals(TypedDiff("", 2), TypedDiff.of("hello", "hel"))
        assertFalse(TypedDiff.of("a", "a").appended.isNotEmpty())
    }

    @Test
    fun anEditInTheMiddleDeletesBackToItAndRetypesTheRest() {
        assertEquals(TypedDiff("Xlo", 2), TypedDiff.of("hello", "helXlo"))
        assertEquals(TypedDiff("llo", 3), TypedDiff.of("hexlo", "hello"))
    }

    @Test
    fun aSameLengthReplacementDeletesTheOldTextAndTypesTheNew() {
        assertEquals(TypedDiff("cat", 3), TypedDiff.of("dog", "cat"))
        assertEquals(TypedDiff("y", 1), TypedDiff.of("abx", "aby"))
    }
}
