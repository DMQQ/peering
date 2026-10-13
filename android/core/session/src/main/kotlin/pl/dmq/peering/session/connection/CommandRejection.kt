package pl.dmq.peering.session.connection

/** A command that was not sent because the host did not declare what it needs. */
data class CommandRejection(val command: String, val missing: HostCapability)
