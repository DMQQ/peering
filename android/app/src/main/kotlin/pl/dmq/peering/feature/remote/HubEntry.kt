package pl.dmq.peering.feature.remote

/** The places the session screen hands over to: the terminal hub, agents and files, and the end of the session. */
enum class HubEntry {
    AGENTS,
    FILES,
    TERMINAL,
    DISCONNECT,
}
