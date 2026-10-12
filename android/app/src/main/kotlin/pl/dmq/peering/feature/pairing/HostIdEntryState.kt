package pl.dmq.peering.feature.pairing

data class HostIdEntryState(
    val text: String = "",
    val error: HostIdError? = null,
) {
    val canSubmit: Boolean get() = text.isNotBlank()
}
