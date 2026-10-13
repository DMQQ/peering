package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.CaptureSourceKind

data class SourceSection(val kind: CaptureSourceKind, val tiles: List<SourceTile>)
