package pl.dmq.peering.feature.remote

import pl.dmq.peering.session.clipboard.ClipboardPush

/** What the phone row says after the user sent something to the computer. */
internal sealed interface ClipboardFeedback {
    data object Confirmed : ClipboardFeedback

    data object Unsupported : ClipboardFeedback

    data class TooLarge(val bytes: Int) : ClipboardFeedback

    /** The send did not happen and there is nothing useful to tell the user, such as a session that just ended. */
    data object Silent : ClipboardFeedback
}

internal fun ClipboardPush?.feedback(): ClipboardFeedback = when (this) {
    ClipboardPush.Sent -> ClipboardFeedback.Confirmed
    ClipboardPush.Unsupported -> ClipboardFeedback.Unsupported
    is ClipboardPush.TooLarge -> ClipboardFeedback.TooLarge(bytes)
    ClipboardPush.NotReady, null -> ClipboardFeedback.Silent
}
