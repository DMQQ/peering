package pl.dmq.peering.session.agent.changes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.AgentChangeKind
import pl.dmq.peering.wire.AgentChangedFile
import pl.dmq.peering.wire.AgentGitBranch

class ReviewHelpersTest {
    private fun file(path: String, kind: AgentChangeKind) = AgentChangedFile(path, kind, 1, 0)

    private val words = ReviewPromptWords(
        intro = "Please address these.",
        removedLine = "(removed)",
        moreLeftOut = { "$it more left out." },
    )

    @Test
    fun aDiffIsNumberedFromItsHunkHeaders() {
        val lines = ReviewDiff.lines(
            "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -10,3 +20,4 @@ fun\n keep\n-gone\n+new one\n+new two\n tail\n\\ No newline",
        )
        assertEquals(
            listOf(DiffLineKind.HUNK, DiffLineKind.CONTEXT, DiffLineKind.REMOVED, DiffLineKind.ADDED, DiffLineKind.ADDED, DiffLineKind.CONTEXT),
            lines.map { it.kind },
        )
        assertEquals(10 to 20, lines[1].oldNumber to lines[1].newNumber)
        assertEquals(11, lines[2].oldNumber)
        assertEquals(21, lines[3].newNumber)
        assertEquals(22, lines[4].newNumber)
        assertEquals(12 to 23, lines[5].oldNumber to lines[5].newNumber)
        assertEquals("gone", lines[2].text)
        assertEquals(11, lines[2].commentNumber)
        assertFalse(lines[0].isCommentable)
    }

    @Test
    fun aDiffWithNoHunkHasNoLines() {
        assertTrue(ReviewDiff.lines("Binary files a and b differ").isEmpty())
    }

    @Test
    fun aHunkHeaderThatDoesNotParseStartsAtOne() {
        val lines = ReviewDiff.lines("@@ nonsense @@\n+x")
        assertEquals(1, lines[1].newNumber)
    }

    @Test
    fun aCommitMessageNamesWhatChanged() {
        assertEquals("Update a.kt", CommitDraft.message(listOf(file("src/a.kt", AgentChangeKind.MODIFIED))))
        assertEquals(
            "Add a.kt and b.kt, update c.kt and remove d.kt",
            CommitDraft.message(
                listOf(
                    file("a.kt", AgentChangeKind.ADDED),
                    file("b.kt", AgentChangeKind.UNTRACKED),
                    file("c.kt", AgentChangeKind.MODIFIED),
                    file("d.kt", AgentChangeKind.DELETED),
                ),
            ),
        )
        assertEquals("", CommitDraft.message(emptyList()))
    }

    @Test
    fun twoFilesWithOneNameAreToldApartByTheirPaths() {
        val message = CommitDraft.message(listOf(file("a/x.kt", AgentChangeKind.MODIFIED), file("b/x.kt", AgentChangeKind.MODIFIED)))
        assertEquals("Update a/x.kt and b/x.kt", message)
    }

    @Test
    fun fourOrMoreFilesAreCounted() {
        val files = (1..4).map { file("f$it", AgentChangeKind.MODIFIED) }
        assertEquals("Update 4 files", CommitDraft.message(files))
    }

    @Test
    fun aCommitTakesEveryFileUntilOneIsTakenOut() {
        val a = file("a", AgentChangeKind.MODIFIED)
        val b = file("b", AgentChangeKind.MODIFIED)
        val selection = CommitSelection().toggle(a)
        assertEquals(listOf(b), selection.chosen(listOf(a, b)))
        assertEquals(listOf(a, b), selection.toggle(a).chosen(listOf(a, b)))
    }

    @Test
    fun aPushIsOfferedOnlyForABranchWithCommitsToSend() {
        val branch = AgentGitBranch("main", "origin/main", "origin", "refs/heads/main", ahead = 2)
        assertEquals(PushOffer.Ready("main", "origin/main", 2), PushOffer.of(branch))
        assertEquals(PushOffer.NothingToPush, PushOffer.of(branch.copy(ahead = 0)))
        assertEquals(PushOffer.Blocked(PushBlock.DETACHED_HEAD), PushOffer.of(branch.copy(head = null)))
        assertEquals(PushOffer.Blocked(PushBlock.NO_UPSTREAM), PushOffer.of(branch.copy(upstream = null)))
        assertEquals(PushOffer.Blocked(PushBlock.NO_UPSTREAM), PushOffer.of(branch.copy(remote = null)))
        assertEquals(PushOffer.Blocked(PushBlock.UNREADABLE), PushOffer.of(null))
    }

    @Test
    fun commentsBecomeOnePromptWithTheirLocations() {
        val text = ReviewPrompt.text(
            listOf(
                ReviewComment(1, "a.kt", "Rename this", line = 4, quote = "  val x = 1 "),
                ReviewComment(2, "b.kt", "Why delete?", line = 9, onRemovedLine = true),
                ReviewComment(3, "c.kt", "Split the file"),
            ),
            words,
        )
        assertEquals(
            "Please address these.\n\na.kt:4\n> val x = 1\nRename this\n\nb.kt:9 (removed)\nWhy delete?\n\nc.kt\nSplit the file",
            text,
        )
    }

    @Test
    fun aLongReviewStopsShortAndSaysHowManyWereLeftOut() {
        val comments = (1..5).map { ReviewComment(it.toLong(), "f$it", "x".repeat(100)) }
        val text = ReviewPrompt.text(comments, words, limit = 200 + 300)
        assertTrue(text.endsWith("3 more left out."))
        assertTrue(text.contains("f2"))
        assertFalse(text.contains("f3"))
    }
}
