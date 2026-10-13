package pl.dmq.peering.feature.remote

import pl.dmq.peering.session.history.SessionRecord

/** What the status pill over the picture says. A null path or latency is not shown. */
data class SessionOverlayState(
    val hostName: String?,
    val latencyMs: Int?,
    val path: SessionRecord.Path?,
    val picture: PictureState,
    val reconnecting: Boolean,
    val quota: QuotaNotice?,
) {
    companion object {
        fun of(
            hostName: String?,
            latencyMs: Int?,
            path: SessionRecord.Path?,
            picture: PictureState,
            reconnecting: Boolean,
            relayMinutesLeft: Int?,
        ): SessionOverlayState = SessionOverlayState(
            hostName = hostName,
            latencyMs = latencyMs,
            path = path,
            picture = picture,
            reconnecting = reconnecting,
            quota = QuotaNotice.of(path, relayMinutesLeft),
        )
    }
}
