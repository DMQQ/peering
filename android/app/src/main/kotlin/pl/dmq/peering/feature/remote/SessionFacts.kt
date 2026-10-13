package pl.dmq.peering.feature.remote

import pl.dmq.peering.session.relay.DirectPathState
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig

/** What the attempt at a direct path came to, for the one case worth explaining: it has not opened. */
enum class DirectPathReport { NOT_TRIED, NO_ADDRESS, PROBING, UNUSABLE }

data class DirectPathRow(val report: DirectPathReport, val peer: String?)

/** The session facts the Settings panel adds to the state, path and latency rows. */
data class SessionFacts(val directPath: DirectPathRow? = null, val video: String? = null) {
    companion object {
        fun of(directPath: DirectPathState?, stream: VideoStreamConfig?) =
            SessionFacts(directPathRow(directPath), stream?.let(::videoLabel))

        /** Null where there is nothing to say: no attempt is made on this link, or the direct path is open. */
        fun directPathRow(state: DirectPathState?): DirectPathRow? = when (state) {
            null, is DirectPathState.Open -> null
            DirectPathState.NotTried -> DirectPathRow(DirectPathReport.NOT_TRIED, null)
            DirectPathState.NoAddress -> DirectPathRow(DirectPathReport.NO_ADDRESS, null)
            is DirectPathState.Probing -> DirectPathRow(DirectPathReport.PROBING, "${state.peer.host}:${state.peer.port}")
            is DirectPathState.AddressUnusable -> DirectPathRow(DirectPathReport.UNUSABLE, "${state.peer.host}:${state.peer.port}")
        }

        fun videoLabel(config: VideoStreamConfig): String {
            val codec = when (config.codec) {
                VideoCodec.HEVC -> "HEVC"
                VideoCodec.H264 -> "H.264"
            }
            return "$codec ${config.pixelWidth}×${config.pixelHeight}"
        }
    }
}
