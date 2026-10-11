package pl.dmq.peering.session.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ComposerDraftTest {
    @Test
    fun filesGoBeforeTheTextAsAtPaths() {
        val draft = ComposerDraft("fix it", listOf("/Users/me/app/a.swift", "/Users/me/app/b.swift"))
        assertEquals("@/Users/me/app/a.swift @/Users/me/app/b.swift fix it", draft.toPrompt())
    }

    @Test
    fun aTextOnlyDraftIsItsText() {
        assertEquals("hello", ComposerDraft("hello").toPrompt())
    }

    @Test
    fun aBlankDraftWithNoFilesCannotBeSent() {
        assertFalse(ComposerDraft("   ").canSend(isUploading = false))
    }

    @Test
    fun aFileAloneCanBeSentButNotWhileItUploads() {
        val withFile = ComposerDraft(attachedPaths = listOf("/x"))
        assertTrue(withFile.canSend(isUploading = false))
        assertFalse(withFile.canSend(isUploading = true))
    }

    @Test
    fun anUploadFolderWithAndWithoutItsSlashGivesOnePath() {
        assertEquals("/Users/me/app/a.txt", attachmentPath("/Users/me/app", "a.txt"))
        assertEquals("/Users/me/app/a.txt", attachmentPath("/Users/me/app/", "a.txt"))
    }

    @Test
    fun eachSessionKeepsItsOwnDraft() {
        val drafts = ComposerDrafts()
            .withDraft("A", ComposerDraft("first chat"))
            .withDraft("B", ComposerDraft("second chat"))
        assertEquals("first chat", drafts.draftFor("A").text)
        assertEquals("second chat", drafts.draftFor("B").text)
        assertTrue(drafts.draftFor("C").isEmpty)
    }

    @Test
    fun anEmptyDraftForgetsTheSession() {
        val drafts = ComposerDrafts().withDraft("A", ComposerDraft("text")).withDraft("A", ComposerDraft())
        assertTrue(drafts.bySession.isEmpty())
    }
}
