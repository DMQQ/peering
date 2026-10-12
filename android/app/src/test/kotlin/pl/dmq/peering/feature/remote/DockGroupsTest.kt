package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.Modifiers

class DockGroupsTest {
    @Test
    fun theControlsComeFirstInOneGroupThenTheEditChords() {
        val groups = DockGroups.of(profile = null)

        assertEquals(listOf("controls", "edits"), groups.map { it.id })
        assertEquals(DockControl.entries, groups.first().controls)
        assertEquals(QuickActions.defaults, groups.last().actions)
    }

    @Test
    fun theApplicationOnScreenGetsItsOwnGroupAfterTheControls() {
        val vscode = ApplicationProfiles.forBundle("com.microsoft.VSCode")

        val groups = DockGroups.of(profile = vscode)

        assertEquals(listOf("controls", "app-com.microsoft.VSCode", "edits"), groups.map { it.id })
        assertEquals("⌘⇧P", groups[1].actions.first().chord)
    }

    @Test
    fun groupBoundariesFallWhereTheItemKindsChange() {
        val vscode = ApplicationProfiles.forBundle("com.microsoft.VSCode")

        val groups = DockGroups.of(profile = vscode)

        assertEquals(DockControl.entries.size, groups[0].size)
        assertTrue(groups.drop(1).all { it.controls.isEmpty() && it.actions.isNotEmpty() })
        assertEquals(DockControl.entries.size + groups[1].size + groups[2].size, groups.sumOf { it.size })
    }

    @Test
    fun noEditsLeavesNoEmptyGroup() {
        assertEquals(listOf("controls"), DockGroups.of(profile = null, edits = emptyList()).map { it.id })
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
