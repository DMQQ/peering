package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.RemoteCommand

/** Passes commands on, except the points and keystrokes a mosaic refuses: the computer cannot tell which window they mean. */
class MosaicGate(private val target: CommandSink, private val showing: () -> Boolean) : CommandSink {
    override fun send(command: RemoteCommand) {
        if (showing() && command.isBlockedByMosaic) return
        target.send(command)
    }
}
