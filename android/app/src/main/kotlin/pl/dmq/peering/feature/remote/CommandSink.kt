package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.RemoteCommand

/** Receives what the user asks the Mac to do. The session sends them in the order given. */
fun interface CommandSink {
    fun send(command: RemoteCommand)
}
