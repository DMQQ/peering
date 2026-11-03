package pl.dmq.peering.feature.agents

import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.remote.dictation.DictationNotice
import pl.dmq.peering.feature.remote.dictation.VoiceDictation
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.theme.PeeringColors

/** Speech heard into the prompt goes after what was already typed, never in place of it. */
object DictatedText {
    fun joined(typed: String, heard: String): String {
        val words = heard.trim()
        if (words.isEmpty()) return typed
        if (typed.isEmpty() || typed.last().isWhitespace()) return typed + words
        return "$typed $words"
    }
}

/**
 * The microphone in the prompt field. The words appear in the field as they are heard and stay editable, and what the
 * person types meanwhile is kept; nothing is sent until they tap Send. A second tap stops listening.
 */
@Composable
internal fun DictationButton(dictation: VoiceDictation, text: String, enabled: Boolean, onText: (String) -> Unit) {
    var splice by remember { mutableStateOf<DictationSplice?>(null) }
    val currentText by rememberUpdatedState(text)
    val currentOnText by rememberUpdatedState(onText)
    val listening = dictation.state == VoiceDictation.State.Listening || dictation.state == VoiceDictation.State.Finishing
    LaunchedEffect(dictation.transcript, listening) {
        val active = splice ?: return@LaunchedEffect
        if (listening) currentOnText(active.apply(currentText, dictation.transcript))
    }
    IconButton(
        onClick = {
            if (listening) {
                dictation.finish()
            } else {
                val started = DictationSplice(text)
                splice = started
                dictation.start { heard ->
                    currentOnText(started.apply(currentText, heard))
                    splice = null
                }
            }
        },
        enabled = enabled,
        modifier = Modifier.size(40.dp),
    ) {
        Icon(
            SessionIcons.microphone,
            contentDescription = stringResource(if (listening) R.string.dictation_done else R.string.dictation_start),
            tint = if (listening) PeeringColors.accent else PeeringColors.ink.copy(alpha = 0.85f),
            modifier = Modifier.size(20.dp),
        )
    }
}

/** Why the microphone could not listen: permission refused, with a way to Settings, or no recogniser on the phone. */
@Composable
internal fun DictationMessage(dictation: VoiceDictation) {
    val denied = dictation.state == VoiceDictation.State.Denied
    if (!denied && dictation.state != VoiceDictation.State.Unavailable) return
    DictationNotice(denied = denied, dismiss = dictation::dismissMessage, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
}
