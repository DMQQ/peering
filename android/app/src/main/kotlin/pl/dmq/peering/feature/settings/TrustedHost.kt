package pl.dmq.peering.feature.settings

/** A Mac this device trusts. [name] is null when the Mac has no name on file. */
data class TrustedHost(val id: String, val name: String?)
