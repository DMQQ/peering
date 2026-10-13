package pl.dmq.peering.session.files

import pl.dmq.peering.wire.TerminalRequest

/** What the platform should do after one event of a download. */
sealed class DownloadStep {
    /** The piece at its offset has been taken; send [requests] and keep going. */
    data class Continue(val plan: FileDownloadPlan, val requests: List<TerminalRequest>) : DownloadStep()

    data class Complete(val plan: FileDownloadPlan) : DownloadStep()

    data class Failed(val reason: DownloadFailure) : DownloadStep()

    /** The event is for another transfer, or arrived after this one ended. */
    data object Ignored : DownloadStep()
}
