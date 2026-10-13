package pl.dmq.peering.feature.remote.dictation

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import pl.dmq.peering.DebugLog

/**
 * Listens through the microphone and turns speech into text, on the device when the recogniser allows it. Used from the
 * main thread only, as SpeechRecognizer requires. [askMicrophone] shows the system permission prompt and reports the answer.
 */
class VoiceDictation(
    private val context: Context,
    private val hasMicrophone: () -> Boolean,
    private val askMicrophone: ((Boolean) -> Unit) -> Unit,
) {
    enum class State { Idle, Listening, Finishing, Denied, Unavailable }

    var state by mutableStateOf(State.Idle)
        private set
    var transcript by mutableStateOf("")
        private set
    var levels by mutableStateOf(DictationLevels())
        private set

    private val handler = Handler(Looper.getMainLooper())
    private var recogniser: SpeechRecognizer? = null
    private var onDevice = false
    private var heard = DictationTranscript()
    private var onFinish: ((String) -> Unit)? = null
    private val settle = Runnable { deliver() }

    /** [onFinish] gets what was heard, once, when listening ends by [finish] or by the recogniser's own end. */
    fun start(onFinish: (String) -> Unit) {
        if (state != State.Idle && state != State.Denied && state != State.Unavailable) return
        this.onFinish = onFinish
        heard = DictationTranscript()
        transcript = ""
        levels = DictationLevels()
        if (hasMicrophone()) begin() else askMicrophone { granted -> if (granted) begin() else state = State.Denied }
    }

    /** Delivers what was heard so far, after giving the recogniser a moment to settle its last word. */
    fun finish() {
        if (state != State.Listening) return
        state = State.Finishing
        recogniser?.stopListening()
        handler.postDelayed(settle, SETTLE_MILLIS)
    }

    fun cancel() {
        onFinish = null
        tearDown()
        state = State.Idle
    }

    fun dismissMessage() {
        if (state == State.Denied || state == State.Unavailable) state = State.Idle
    }

    private fun begin() {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            state = State.Unavailable
            return
        }
        try {
            val speech = createRecogniser()
            recogniser = speech
            speech.setRecognitionListener(listener)
            speech.startListening(listenIntent())
            state = State.Listening
        } catch (failure: RuntimeException) {
            DebugLog.w("PeeringDictation", { "could not start listening" }, failure)
            tearDown()
            state = State.Unavailable
        }
    }

    private fun createRecogniser(): SpeechRecognizer {
        onDevice = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        return if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
    }

    private fun listenIntent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, onDevice)
        .putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)

    private val listener = object : RecognitionListener {
        override fun onRmsChanged(rmsdB: Float) {
            if (state == State.Listening) levels = levels.added(rmsdB)
        }

        override fun onPartialResults(partialResults: Bundle?) {
            val words = partialResults.firstResult() ?: return
            if (state != State.Listening && state != State.Finishing) return
            heard = heard.withPartial(words)
            transcript = heard.text
        }

        override fun onResults(results: Bundle?) {
            if (state != State.Listening && state != State.Finishing) return
            heard = heard.withFinished(results.firstResult().orEmpty())
            transcript = heard.text
            if (state == State.Finishing) deliver() else listenAgain()
        }

        override fun onError(error: Int) {
            when (state) {
                State.Finishing -> deliver()
                State.Listening -> failed(RecogniserError.of(error))
                else -> Unit
            }
        }

        override fun onReadyForSpeech(params: Bundle?) = Unit

        override fun onBeginningOfSpeech() = Unit

        override fun onBufferReceived(buffer: ByteArray?) = Unit

        override fun onEndOfSpeech() = Unit

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    private fun failed(error: RecogniserError) {
        when (error) {
            RecogniserError.ListenAgain -> listenAgain()
            RecogniserError.Denied, RecogniserError.Unavailable -> {
                val text = heard.text
                if (text.isNotEmpty()) {
                    deliver()
                } else {
                    tearDown()
                    state = if (error == RecogniserError.Denied) State.Denied else State.Unavailable
                }
            }
        }
    }

    /** A recogniser ends a phrase on a pause, but a dictation runs until the person says done. */
    private fun listenAgain() {
        try {
            recogniser?.startListening(listenIntent())
        } catch (failure: RuntimeException) {
            DebugLog.w("PeeringDictation", { "could not listen again" }, failure)
            failed(RecogniserError.Unavailable)
        }
    }

    private fun deliver() {
        val finish = onFinish
        val text = heard.text
        onFinish = null
        tearDown()
        state = State.Idle
        finish?.invoke(text)
    }

    private fun tearDown() {
        handler.removeCallbacks(settle)
        recogniser?.let {
            it.setRecognitionListener(null)
            it.destroy()
        }
        recogniser = null
    }

    private fun Bundle?.firstResult(): String? =
        this?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()

    private companion object {
        const val SETTLE_MILLIS = 1000L
    }
}
