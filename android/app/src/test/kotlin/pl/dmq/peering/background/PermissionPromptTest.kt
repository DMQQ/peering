package pl.dmq.peering.background

import org.junit.Assert.assertEquals
import org.junit.Test

class PermissionPromptTest {
    @Test
    fun theFirstSessionExplainsBeforeAskingOnceOnAndroid13() {
        assertEquals(PermissionStep.ExplainThenAsk, PermissionPrompt.onFirstSession(33, granted = false, enabled = true, explainedBefore = false))
        assertEquals(PermissionStep.None, PermissionPrompt.onFirstSession(33, granted = false, enabled = true, explainedBefore = true))
    }

    @Test
    fun nothingIsAskedWhenGrantedDisabledOrBeforeAndroid13() {
        assertEquals(PermissionStep.None, PermissionPrompt.onFirstSession(33, granted = true, enabled = true, explainedBefore = false))
        assertEquals(PermissionStep.None, PermissionPrompt.onFirstSession(34, granted = false, enabled = false, explainedBefore = false))
        assertEquals(PermissionStep.None, PermissionPrompt.onFirstSession(32, granted = false, enabled = true, explainedBefore = false))
    }

    @Test
    fun turningNotificationsOnAsksThenSendsARefusedUserToSettings() {
        assertEquals(PermissionStep.Ask, PermissionPrompt.onToggledOn(33, granted = false, refusedBefore = false))
        assertEquals(PermissionStep.OpenSettings, PermissionPrompt.onToggledOn(33, granted = false, refusedBefore = true))
        assertEquals(PermissionStep.None, PermissionPrompt.onToggledOn(33, granted = true, refusedBefore = true))
        assertEquals(PermissionStep.None, PermissionPrompt.onToggledOn(30, granted = false, refusedBefore = false))
    }
}
