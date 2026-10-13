package pl.dmq.peering.session.flows

import pl.dmq.peering.session.connection.ClientAction
import pl.dmq.peering.session.connection.ClientStateMachine
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.FrameDecoder
import pl.dmq.peering.wire.FrameEncoder

/**
 * Connects a phone's state machine to a [ScriptedPairingHost] through bytes: every frame is encoded, pushed through a
 * decoder on the other side, and the answers come back the same way. Actions are collected in the order they happen.
 */
class PairingLink(
    private val machine: ClientStateMachine,
    private val host: ScriptedPairingHost,
) {
    private val toPhone = FrameDecoder()
    val actions = mutableListOf<ClientAction>()

    fun start() = dispatch(machine.start())

    fun confirm(accepted: Boolean, secret: ByteArray? = null) = dispatch(machine.confirm(accepted, secret))

    private fun dispatch(next: List<ClientAction>) {
        for (action in next) {
            actions += action
            if (action is ClientAction.Send) deliverToHost(action.frame)
        }
    }

    private fun deliverToHost(frame: Frame) {
        host.receive(FrameEncoder.encode(frame.kind, frame.payload)).forEach(::deliverToPhone)
    }

    private fun deliverToPhone(frame: Frame) {
        toPhone.push(FrameEncoder.encode(frame.kind, frame.payload))
        while (true) {
            val received = toPhone.next() ?: break
            dispatch(machine.onFrame(received))
        }
    }
}
