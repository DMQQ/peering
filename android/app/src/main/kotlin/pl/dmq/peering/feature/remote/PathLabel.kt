package pl.dmq.peering.feature.remote

import pl.dmq.peering.R
import pl.dmq.peering.session.history.SessionRecord

internal fun SessionRecord.Path.labelRes(): Int = when (this) {
    SessionRecord.Path.LAN -> R.string.overlay_path_lan
    SessionRecord.Path.RELAY -> R.string.overlay_path_relay
    SessionRecord.Path.DIRECT -> R.string.overlay_path_direct
}
