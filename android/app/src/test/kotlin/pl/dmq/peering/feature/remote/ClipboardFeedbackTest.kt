package pl.dmq.peering.feature.remote

import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.clipboard.ClipboardPush

class ClipboardFeedbackTest {
    @Test
    fun aSentPictureIsConfirmed() {
        assertEquals(ClipboardFeedback.Confirmed, ClipboardPush.Sent.feedback())
    }

    @Test
    fun aRefusalCarriesWhatTheRowSays() {
        assertEquals(ClipboardFeedback.Unsupported, ClipboardPush.Unsupported.feedback())
        assertEquals(ClipboardFeedback.TooLarge(9), ClipboardPush.TooLarge(9).feedback())
    }

    @Test
    fun aSessionThatIsNotReadyOrAnUnreadablePictureSaysNothing() {
        assertEquals(ClipboardFeedback.Silent, ClipboardPush.NotReady.feedback())
        assertEquals(ClipboardFeedback.Silent, (null as ClipboardPush?).feedback())
    }
}
