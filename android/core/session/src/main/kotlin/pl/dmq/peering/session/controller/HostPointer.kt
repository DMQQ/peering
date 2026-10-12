package pl.dmq.peering.session.controller

import pl.dmq.peering.wire.NormalizedPoint

/** A pointer position the computer reported. [serial] grows with every report, so the same point twice is still news. */
data class HostPointer(val point: NormalizedPoint, val serial: Int)
