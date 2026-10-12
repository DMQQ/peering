package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.RemoteCommand

class RecordingCommandSink : CommandSink {
    val sent = mutableListOf<RemoteCommand>()

    override fun send(command: RemoteCommand) {
        sent += command
    }
}
