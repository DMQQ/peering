package pl.dmq.peering.feature.connect

/** A host this device is paired with. [name] is the name the user gave it, or null when none is known.
 * [canWake] is true when a hardware address is on file. */
data class PairedHost(val id: String, val name: String?, val canWake: Boolean = false)
