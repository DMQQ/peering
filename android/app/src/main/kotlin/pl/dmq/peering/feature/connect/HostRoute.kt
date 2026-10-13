package pl.dmq.peering.feature.connect

/** How a computer is reachable right now: seen on this network, announced through the relay only, or neither. */
enum class HostRoute { Local, Relay, None }
