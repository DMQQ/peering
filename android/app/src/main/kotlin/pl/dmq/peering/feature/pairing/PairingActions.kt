package pl.dmq.peering.feature.pairing

/** What the pairing screen can ask for. Every callback is required; [onScan] is null where the camera is not offered. */
data class PairingActions(
    val onDigitsEntered: (String) -> Unit,
    val onCancel: () -> Unit,
    val onFinished: () -> Unit,
    val onScan: (() -> Unit)?,
)
