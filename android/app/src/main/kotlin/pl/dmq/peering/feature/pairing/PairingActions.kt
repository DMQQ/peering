package pl.dmq.peering.feature.pairing

/** What the pairing screen can ask for; a preview passes the defaults. */
data class PairingActions(
    val onDigitsEntered: (String) -> Unit = {},
    val onCancel: () -> Unit = {},
    val onFinished: () -> Unit = {},
    val onScan: (() -> Unit)? = null,
)
