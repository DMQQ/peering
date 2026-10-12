package pl.dmq.peering.feature.connect

/** Everything the Connect screen can ask for, so the layout takes one value. Every callback is required; [onScan] is null where the camera is not offered. */
data class ConnectActions(
    val onConnect: (String) -> Unit,
    val onConnectVia: (String, ConnectVia) -> Unit,
    val onPair: (String) -> Unit,
    val onRename: (String, String) -> Unit,
    val onDismissMessage: () -> Unit,
    val onForget: (String) -> Unit,
    val onConnectAddress: (host: String, port: String) -> Unit,
    val onSearchAgain: () -> Unit,
    val onOpenWifiSettings: () -> Unit,
    val onEntryTextChanged: (String) -> Unit,
    val onEntrySubmit: () -> Unit,
    val onScan: (() -> Unit)?,
)
