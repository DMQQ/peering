package pl.dmq.peering.session.files

/** Why a download stopped before it was complete. Messages are left to the platform, which owns the strings. */
sealed class DownloadFailure {
    data object TooLarge : DownloadFailure()

    /** The Mac sent an empty piece before the size it declared was reached. */
    data object ShortRead : DownloadFailure()

    /** The Mac said the transfer failed; [message] is its own text. */
    data class Transfer(val message: String) : DownloadFailure()
}
