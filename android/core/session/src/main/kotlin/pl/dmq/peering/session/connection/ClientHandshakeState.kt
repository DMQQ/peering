package pl.dmq.peering.session.connection

/** Where the client stands in the handshake. [Ready] and [Failed] are terminal for the handshake. */
enum class ClientHandshakeState {
    Idle,
    AwaitingServerHello,
    AwaitingServerCommit,
    AwaitingServerReveal,
    AwaitingUserConfirmation,
    AwaitingPairResult,
    Ready,
    Failed,
}
