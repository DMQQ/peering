package pl.dmq.peering.feature.remote

import pl.dmq.peering.session.history.SessionRecord

/** A warning about relay time. Only a session on the relay uses relay time; an unlimited plan has no minutes to count. */
sealed class QuotaNotice {
    data class Low(val minutesLeft: Int) : QuotaNotice()

    data object Exhausted : QuotaNotice()

    companion object {
        const val LOW_THRESHOLD_MINUTES = 5

        fun of(path: SessionRecord.Path?, relayMinutesLeft: Int?): QuotaNotice? {
            if (path != SessionRecord.Path.RELAY || relayMinutesLeft == null) return null
            return when {
                relayMinutesLeft <= 0 -> Exhausted
                relayMinutesLeft <= LOW_THRESHOLD_MINUTES -> Low(relayMinutesLeft)
                else -> null
            }
        }
    }
}
