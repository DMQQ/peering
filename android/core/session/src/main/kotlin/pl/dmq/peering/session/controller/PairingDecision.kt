package pl.dmq.peering.session.controller

/** The user's answer to a six digit code: whether the digits match, and the QR secret when they were read from a code. */
internal class PairingDecision(val accepted: Boolean, val secret: ByteArray?)
