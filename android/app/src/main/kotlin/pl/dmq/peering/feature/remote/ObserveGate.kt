package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.RemoteCommand

/** Passes commands on, except what the user does while only observing: touches and keys must never reach the computer. */
class ObserveGate(private val target: CommandSink, private val observing: () -> Boolean) : CommandSink {
    override fun send(command: RemoteCommand) {
        if (observing() && command.isUserInput) return
        target.send(command)
    }
}
