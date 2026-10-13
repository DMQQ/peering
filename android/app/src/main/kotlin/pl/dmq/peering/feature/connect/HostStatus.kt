package pl.dmq.peering.feature.connect

/** Declared in the order the list shows them: a connected host first, then one that is up, then one not seen. */
enum class HostStatus { Connected, Online, Unknown }
