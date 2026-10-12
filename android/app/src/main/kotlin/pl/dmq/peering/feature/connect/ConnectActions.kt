package pl.dmq.peering.feature.connect

/** Everything the Connect screen can ask for, so the layout takes one value and a preview can pass no-ops. */
data class ConnectActions(
    val onConnect: (String) -> Unit = {},
    val onPair: (String) -> Unit = {},
    val onForget: (String) -> Unit = {},
    val onConnectAddress: (host: String, port: String) -> Unit = { _, _ -> },
    val onSearchAgain: () -> Unit = {},
    val onOpenWifiSettings: () -> Unit = {},
    val onEntryTextChanged: (String) -> Unit = {},
    val onEntrySubmit: () -> Unit = {},
    val onScan: (() -> Unit)? = null,
)
