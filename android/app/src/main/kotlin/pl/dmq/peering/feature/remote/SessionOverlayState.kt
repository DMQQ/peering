package pl.dmq.peering.feature.remote

import pl.dmq.peering.session.history.SessionRecord

/** What the status line over the picture says. A null path or latency is not shown. */
data class SessionOverlayState(
    val latencyMs: Int?,
    val path: SessionRecord.Path?,
    val picture: PictureState,
    val quota: QuotaNotice?,
) {
    companion object {
        fun of(
            latencyMs: Int?,
            path: SessionRecord.Path?,
            picture: PictureState,
            relayMinutesLeft: Int?,
        ): SessionOverlayState = SessionOverlayState(
            latencyMs = latencyMs,
            path = path,
            picture = picture,
            quota = QuotaNotice.of(path, relayMinutesLeft),
        )
    }
}
