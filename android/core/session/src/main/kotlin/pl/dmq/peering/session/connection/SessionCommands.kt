package pl.dmq.peering.session.connection

import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CommandCoalescer
import pl.dmq.peering.wire.Coalescing
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.JoystickMove
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.QualityTier
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.Scroll
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.SetStreamQuality

/**
 * Turns the commands the user makes into frames the host will accept. A command whose capability the host did not
 * declare is never framed: it is recorded in [takeRejections] instead. Commands offered through [offer] are merged the
 * way the wire's [CommandCoalescer] merges them, so high-rate input does not flood the control connection.
 */
class SessionCommands(private val host: ServerHello) {
    private val coalescer = CommandCoalescer<RemoteCommand>(
        policy = { it.coalescing },
        merge = ::accumulate,
    )
    private val rejections = mutableListOf<CommandRejection>()

    var latestCatalog: CaptureCatalog? = null
        private set

    /** The frame for [command] now, or null when the host did not declare what the command needs. */
    fun send(command: RemoteCommand): Frame? {
        if (!allowed(command)) return null
        return frame(command)
    }

    /** Queues [command] for the next [drain], or records a rejection when the host cannot take it. */
    fun offer(command: RemoteCommand) {
        if (allowed(command)) coalescer.offer(command)
    }

    /** Every queued command as a frame, in arrival order. The queue is empty afterwards. */
    fun drain(): List<Frame> = coalescer.drain().map(::frame)

    /** The quality the phone asks for as soon as a session is ready, before the user chooses anything. */
    fun firstQualityCommand(tier: QualityTier): RemoteCommand = SetStreamQuality(fps = 0, bitrateKbps = tier.kbps)

    /** Reads a catalogue frame. Returns null when the frame is not a catalogue or does not parse. */
    fun onCatalog(frame: Frame): CaptureCatalog? {
        if (frame.kind != MessageKind.Catalog) return null
        val catalog = HandshakeFrames.parsed { CaptureCatalog.parse(frame.payload.decodeToString()) } ?: return null
        latestCatalog = catalog
        return catalog
    }

    /** The rejections since the last call, cleared. */
    fun takeRejections(): List<CommandRejection> {
        val taken = rejections.toList()
        rejections.clear()
        return taken
    }

    private fun allowed(command: RemoteCommand): Boolean {
        val required = HostCapability.requiredBy(command) ?: return true
        if (required.declaredBy(host)) return true
        rejections += CommandRejection(command::class.simpleName ?: "command", required)
        return false
    }

    private fun frame(command: RemoteCommand): Frame =
        Frame(MessageKind.Command, command.toJson().toByteArray(Charsets.UTF_8))

    private companion object {
        fun accumulate(older: RemoteCommand, newer: RemoteCommand): RemoteCommand = when {
            older is Scroll && newer is Scroll -> Scroll(older.dx + newer.dx, older.dy + newer.dy)
            older is JoystickMove && newer is JoystickMove -> JoystickMove(older.dx + newer.dx, older.dy + newer.dy)
            else -> error("only scroll and joystick input accumulates, not ${older::class.simpleName}")
        }
    }
}
