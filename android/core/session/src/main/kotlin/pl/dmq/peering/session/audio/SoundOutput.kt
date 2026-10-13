package pl.dmq.peering.session.audio

/** Where the phone stands with the system on who may play. */
enum class FocusState { NONE, HELD, DUCKED, LOST }

/** What decides whether the computer's sound comes out of the phone. */
data class SoundConditions(
    val muted: Boolean,
    val appInForeground: Boolean,
    val focus: FocusState,
    /** The output the sound was on went away, such as headphones pulled out: stay quiet until the person is back. */
    val routeLost: Boolean,
) {
    val wantsFocus: Boolean get() = !muted && appInForeground && !routeLost

    val output: SoundOutput
        get() = when {
            !wantsFocus -> SoundOutput.SILENT
            focus == FocusState.HELD -> SoundOutput.FULL
            focus == FocusState.DUCKED -> SoundOutput.DUCKED
            else -> SoundOutput.SILENT
        }
}

enum class SoundOutput(val volume: Float) {
    SILENT(0f),
    DUCKED(0.2f),
    FULL(1f),
}
