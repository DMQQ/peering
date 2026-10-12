package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.Modifiers

class DockPagesTest {
    @Test
    fun theClosedDockShowsFiveControlsToAPageThenTheEditChords() {
        val pages = DockPages.of(expanded = false, profile = null)

        assertEquals(
            listOf(DockControl.SOURCES, DockControl.KEYS, DockControl.CLIPBOARD, DockControl.SHORTCUTS, DockControl.TAB),
            pages.first().controls,
        )
        assertEquals(listOf("controls-0", "controls-1", "controls-2", "edits-0"), pages.map { it.id })
    }

    @Test
    fun theOpenDockFitsEveryControlOnOnePage() {
        val pages = DockPages.of(expanded = true, profile = null)

        assertEquals(listOf("controls-0", "edits-0"), pages.map { it.id })
        assertEquals(DockControl.entries, pages.first().controls)
    }

    @Test
    fun theApplicationOnScreenTakesTheSecondPlace() {
        val vscode = ApplicationProfiles.forBundle("com.microsoft.VSCode")

        val pages = DockPages.of(expanded = false, profile = vscode)

        assertEquals(listOf("controls-0", "app-com.microsoft.VSCode-0", "controls-1", "controls-2", "edits-0"), pages.map { it.id })
        assertEquals("⌘⇧P", pages[1].actions.first().chord)
    }

    @Test
    fun quitAsksBeforeItIsSent() {
        val quit = QuickActions.defaults.single { it.id == "quit" }

        assertTrue(quit.confirms)
        assertEquals(Modifiers.COMMAND, quit.modifiers)
        assertEquals(12, quit.keyCode)
    }

    @Test
    fun anUnknownApplicationHasNoProfile() {
        assertEquals(null, ApplicationProfiles.forBundle("com.example.unknown"))
        assertEquals(null, ApplicationProfiles.forBundle(null))
    }
}
