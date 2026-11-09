package pl.dmq.peering.feature.agents.routines

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.agents.FakeAgentsPort
import pl.dmq.peering.feature.agents.FolderPicker
import pl.dmq.peering.feature.agents.FolderRecents
import pl.dmq.peering.feature.agents.InMemoryFolderRecentsStore
import pl.dmq.peering.wire.AgentEvent
import pl.dmq.peering.wire.AgentPermissionMode
import pl.dmq.peering.wire.AgentRoutine
import pl.dmq.peering.wire.AgentRoutineSchedule

class RoutinesPresenterTest {
    private val port = FakeAgentsPort()
    private val browsed = mutableListOf<String?>()
    private val scope = CoroutineScope(UnconfinedTestDispatcher())
    private val folders = FolderPicker({ browsed += it }, scope)
    private val presenter = RoutinesPresenter(port, listOf("claude", "codex"), folders, FolderRecents(InMemoryFolderRecentsStore(), "mac"), scope)

    private val existing = AgentRoutine(
        "0A1B2C3D-0000-4000-8000-00000000000F", "Nightly", "codex", "/work", "Test",
        AgentRoutineSchedule.Every(120), AgentPermissionMode.PLAN, true, notifiesWhenDone = false,
    )

    private fun fillAndFolder() {
        presenter.startNew()
        presenter.change { it.copy(name = "Morning", prompt = "Review") }
        presenter.chooseFolder()
        folders.onEvent(AgentEvent.Directory("/Users/me/app", emptyList(), truncated = false))
        assertTrue(presenter.useChosenFolder())
    }

    @Test
    fun aNewRoutineCannotBeSavedUntilAFolderIsChosen() {
        presenter.startNew()
        presenter.change { it.copy(name = "Morning", prompt = "Review") }
        presenter.save()
        assertTrue(port.saved.isEmpty())
        assertTrue(presenter.ui.value.page is RoutinesPage.Editor)
    }

    @Test
    fun savingSendsTheRoutineWithNotifyOnAndReturnsToTheList() {
        fillAndFolder()
        presenter.save()
        val sent = port.saved.single()
        assertEquals("/Users/me/app", sent.directory)
        assertEquals(true, sent.notifiesWhenDone)
        assertEquals(RoutinesPage.List, presenter.ui.value.page)
    }

    @Test
    fun theNotifySwitchIsSentAsChosen() {
        fillAndFolder()
        presenter.change { it.copy(notifiesWhenDone = false) }
        presenter.save()
        assertEquals(false, port.saved.single().notifiesWhenDone)
    }

    @Test
    fun editingAnExistingRoutineKeepsItsIdAndAllowsDeleting() {
        presenter.edit(existing)
        presenter.delete()
        assertEquals(listOf("deleteRoutine:${existing.id}"), port.calls)
        assertEquals(RoutinesPage.List, presenter.ui.value.page)
    }

    @Test
    fun aNewRoutineHasNothingToDelete() {
        presenter.startNew()
        presenter.delete()
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun backwardsGoesFromFolderToEditorToList() {
        presenter.startNew()
        presenter.chooseFolder()
        assertTrue(presenter.ui.value.page is RoutinesPage.Folder)
        assertTrue(presenter.back())
        assertTrue(presenter.ui.value.page is RoutinesPage.Editor)
        assertTrue(presenter.back())
        assertFalse(presenter.back())
    }

    @Test
    fun theFolderPageOpensOnTheRoutinesCurrentFolder() {
        presenter.edit(existing)
        presenter.chooseFolder()
        assertEquals(listOf<String?>("/work"), browsed)
    }

    @Test
    fun changingTheAgentFallsBackToADefaultModeTheAgentOffers() {
        presenter.edit(existing.copy(permissionMode = AgentPermissionMode.AUTO))
        presenter.chooseAgent("claude")
        val editor = presenter.ui.value.page as RoutinesPage.Editor
        assertEquals("claude", editor.draft.agentID)
        assertEquals(AgentPermissionMode.AUTO, editor.draft.permissionMode)
    }

    @Test
    fun runNowAndRefreshAskTheMac() {
        presenter.refresh()
        presenter.runNow(existing.id)
        assertEquals(listOf("listRoutines", "runRoutineNow:${existing.id}"), port.calls)
    }

    @Test
    fun theMacsRefusalAndListShowOnTheScreen() {
        port.routineList.value = listOf(existing)
        port.routineProblem.value = "No such folder"
        assertEquals(listOf(existing), presenter.ui.value.routines)
        assertEquals("No such folder", presenter.ui.value.failure)
        assertNull(RoutinesPresenter(FakeAgentsPort(), listOf("claude"), folders, FolderRecents(InMemoryFolderRecentsStore(), "x"), scope).ui.value.routines)
    }
}
