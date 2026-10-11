package pl.dmq.peering.session.files

import pl.dmq.peering.wire.TerminalRequest

/** The next state, the requests that follow it, and any download bytes to write. Nothing is sent from inside a fold. */
internal class FileBrowserStep(
    val state: FileBrowserState,
    val requests: List<TerminalRequest> = emptyList(),
    val piece: DownloadPiece? = null,
)
