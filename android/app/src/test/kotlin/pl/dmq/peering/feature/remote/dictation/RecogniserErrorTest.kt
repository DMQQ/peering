package pl.dmq.peering.feature.remote.dictation

import android.speech.SpeechRecognizer
import org.junit.Assert.assertEquals
import org.junit.Test

class RecogniserErrorTest {
    @Test
    fun aPauseWithoutWordsListensAgain() {
        assertEquals(RecogniserError.ListenAgain, RecogniserError.of(SpeechRecognizer.ERROR_NO_MATCH))
        assertEquals(RecogniserError.ListenAgain, RecogniserError.of(SpeechRecognizer.ERROR_SPEECH_TIMEOUT))
    }

    @Test
    fun aMissingPermissionIsDenied() {
        assertEquals(RecogniserError.Denied, RecogniserError.of(SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS))
    }

    @Test
    fun anythingElseMeansDictationCannotRun() {
        assertEquals(RecogniserError.Unavailable, RecogniserError.of(SpeechRecognizer.ERROR_NETWORK))
        assertEquals(RecogniserError.Unavailable, RecogniserError.of(SpeechRecognizer.ERROR_RECOGNIZER_BUSY))
    }
}
