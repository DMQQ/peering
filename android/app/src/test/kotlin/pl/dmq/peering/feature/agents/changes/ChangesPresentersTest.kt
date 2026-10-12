package pl.dmq.peering.feature.agents.changes

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.agents.FakeAgentsPort
import pl.dmq.peering.session.agent.changes.AgentChangesState
import pl.dmq.peering.session.agent.changes.PushBlock
import pl.dmq.peering.session.agent.changes.PushOffer
import pl.dmq.peering.session.agent.changes.ReviewDiff
import pl.dmq.peering.session.agent.changes.ReviewPromptWords
import pl.dmq.peering.wire.AgentChangeKind
import pl.dmq.peering.wire.AgentChangedFile
import pl.dmq.peering.wire.AgentChangesReport
import pl.dmq.peering.wire.AgentGitBranch
import pl.dmq.peering.wire.AgentGitOperation
import pl.dmq.peering.wire.AgentGitResult

class ChangesPresentersTest {
    private val id = "A"
    private val scope = CoroutineScope(UnconfinedTestDispatcher())
    private val port = FakeAgentsPort()
    private val words = ReviewPromptWords("Please address these.", "(removed)") { "$it more." }

    private val files = listOf(
        AgentChangedFile("src/a.kt", AgentChangeKind.MODIFIED, added = 3, removed = 1, diff = "@@ -1,2 +1,4 @@\n keep\n-old\n+new\n+newer\n"),
        AgentChangedFile("b.md", AgentChangeKind.UNTRACKED, added = 5, removed = 0),
    )

    private fun report(branch: AgentGitBranch? = null) = AgentChangesReport(true, files, files.map { it.path }, branch = branch)

    private fun hold(state: AgentChangesState) {
        port.changesState.value = mapOf(id to state)
    }

    @Test
    fun theScreenWaitsUntilTheComputerAnswers() {
        val ui = ChangesPresenter(port, id, scope).ui.value
        assertTrue(ui.waiting)
        assertFalse(ui.canCommit)
    }

    @Test
    fun aReportBecomesRowsWithTotals() {
        val presenter = ChangesPresenter(port, id, scope)
        hold(AgentChangesState(report()))
        val ui = presenter.ui.value
        assertEquals(listOf("a.kt", "b.md"), ui.entries.map { it.name })
        assertEquals("src", ui.entries[0].folder)
        assertEquals("", ui.entries[1].folder)
        assertEquals(8 to 1, ui.added to ui.removed)
        assertTrue(ui.canCommit)
    }

    @Test
    fun aFolderThatIsNotARepositoryCannotBeCommitted() {
        val presenter = ChangesPresenter(port, id, scope)
        hold(AgentChangesState(AgentChangesReport.failure("Not a git folder")))
        assertFalse(presenter.ui.value.canCommit)
        assertEquals("Not a git folder", presenter.ui.value.message)
        assertFalse(presenter.ui.value.waiting)
    }

    @Test
    fun refreshAsksTheComputer() {
        ChangesPresenter(port, id, scope).refresh()
        assertEquals(listOf("changes:A"), port.calls)
    }

    @Test
    fun commentsAreCountedPerFileAndSentAsOnePrompt() {
        val presenter = ChangesPresenter(port, id, scope)
        hold(AgentChangesState(report()))
        val lines = ReviewDiff.lines(files[0].diff!!)
        presenter.addComment("src/a.kt", "  Why? ", lines[2])
        presenter.addComment("src/a.kt", "Rename", lines[3])
        presenter.addComment("b.md", "Whole file")
        presenter.addComment("b.md", "   ")
        assertEquals(2, presenter.ui.value.entries[0].commentCount)
        assertEquals(3, presenter.ui.value.comments.size)

        assertTrue(presenter.sendReview(words))
        assertEquals(
            "prompt:A:Please address these.\n\nsrc/a.kt:2 (removed)\n> old\nWhy?\n\nsrc/a.kt:2\n> new\nRename\n\nb.md\nWhole file",
            port.calls.single(),
        )
        assertTrue(presenter.ui.value.comments.isEmpty())
    }

    @Test
    fun sendingWithNoCommentsSendsNothing() {
        assertFalse(ChangesPresenter(port, id, scope).sendReview(words))
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun aRemovedCommentIsNotSent() {
        val presenter = ChangesPresenter(port, id, scope)
        presenter.addComment("a", "one")
        presenter.addComment("b", "two")
        presenter.removeComment(presenter.ui.value.comments.first().id)
        assertEquals(listOf("b"), presenter.ui.value.comments.map { it.path })
    }

    @Test
    fun theCommitStartsWithEveryFileAndADraftMessage() {
        val presenter = CommitPresenter(port, id, scope)
        hold(AgentChangesState(report()))
        val ui = presenter.ui.value
        assertEquals(2, ui.chosenCount)
        assertEquals("Add b.md and update a.kt", ui.message)
        assertTrue(ui.canCommit)
    }

    @Test
    fun takingAFileOutChangesTheDraftAndWhatIsSent() {
        val presenter = CommitPresenter(port, id, scope)
        hold(AgentChangesState(report()))
        presenter.toggle("b.md")
        assertEquals("Update a.kt", presenter.ui.value.message)
        presenter.commit()
        assertEquals(listOf("commit:A:src/a.kt:Update a.kt"), port.calls)
    }

    @Test
    fun aMessageTheReaderTypedSurvivesTheSelectionChanging() {
        val presenter = CommitPresenter(port, id, scope)
        hold(AgentChangesState(report()))
        presenter.editMessage("My own words")
        presenter.toggle("b.md")
        assertEquals("My own words", presenter.ui.value.message)
    }

    @Test
    fun nothingIsCommittedWithoutFilesOrAMessage() {
        val presenter = CommitPresenter(port, id, scope)
        hold(AgentChangesState(report()))
        presenter.editMessage("  ")
        presenter.commit()
        presenter.editMessage("ok")
        presenter.toggle("b.md")
        presenter.toggle("src/a.kt")
        presenter.commit()
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun nothingIsCommittedWhileAnotherGitStepRuns() {
        val presenter = CommitPresenter(port, id, scope)
        hold(AgentChangesState(report(), gitBusy = AgentGitOperation.PUSH))
        presenter.commit()
        assertTrue(port.calls.isEmpty())
    }

    @Test
    fun aSuccessfulCommitClearsTheSelectionAndTheTypedMessage() {
        val presenter = CommitPresenter(port, id, scope)
        hold(AgentChangesState(report()))
        presenter.editMessage("Typed")
        presenter.toggle("b.md")
        hold(AgentChangesState(report(), gitResult = AgentGitResult(AgentGitOperation.COMMIT, true, "done")))
        assertEquals(2, presenter.ui.value.chosenCount)
        assertEquals("Add b.md and update a.kt", presenter.ui.value.message)
    }

    @Test
    fun aFailedCommitKeepsWhatTheReaderChose() {
        val presenter = CommitPresenter(port, id, scope)
        hold(AgentChangesState(report()))
        presenter.editMessage("Typed")
        hold(AgentChangesState(report(), gitResult = AgentGitResult(AgentGitOperation.COMMIT, false, "hook failed")))
        assertEquals("Typed", presenter.ui.value.message)
    }

    @Test
    fun aPushIsSentOnlyWhenTheBranchHasCommitsToSend() {
        val presenter = CommitPresenter(port, id, scope)
        val branch = AgentGitBranch("main", "origin/main", "origin", "refs/heads/main", ahead = 1)
        hold(AgentChangesState(report(branch.copy(ahead = 0))))
        presenter.push()
        assertTrue(port.calls.isEmpty())
        hold(AgentChangesState(report(branch)))
        assertEquals(PushOffer.Ready("main", "origin/main", 1), presenter.ui.value.push)
        presenter.push()
        assertEquals(listOf("push:A"), port.calls)
    }

    @Test
    fun aBranchWithoutAnUpstreamBlocksThePush() {
        val presenter = CommitPresenter(port, id, scope)
        hold(AgentChangesState(report(AgentGitBranch("main"))))
        assertEquals(PushOffer.Blocked(PushBlock.NO_UPSTREAM), presenter.ui.value.push)
        presenter.push()
        assertTrue(port.calls.isEmpty())
    }
}
