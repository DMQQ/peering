package pl.dmq.peering.feature.remote.dictation

import android.speech.SpeechRecognizer

/** What a SpeechRecognizer error code means for a dictation that is listening. */
enum class RecogniserError {
    /** The phrase ended without words: listen again. */
    ListenAgain,
    Denied,
    Unavailable;

    companion object {
        fun of(code: Int): RecogniserError = when (code) {
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> ListenAgain
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> Denied
            else -> Unavailable
        }
    }
}
