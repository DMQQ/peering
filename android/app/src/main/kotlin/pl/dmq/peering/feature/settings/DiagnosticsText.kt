package pl.dmq.peering.feature.settings

/** What "Copy diagnostics" puts on the clipboard: enough to answer the first questions asked about a failure, and nothing from a session. */
internal fun diagnosticsText(
    appVersion: String,
    androidRelease: String,
    deviceModel: String,
    deviceId: String,
    pairedCount: Int,
    allowsRelay: Boolean,
    paidRelay: Boolean,
): String = listOf(
    "Peering $appVersion",
    "Android $androidRelease, $deviceModel",
    "Device ID: $deviceId",
    "Paired computers: $pairedCount",
    "Relay connections: ${if (allowsRelay) "allowed" else "off"}",
    "Plan: ${if (paidRelay) "paid" else "free"}",
).joinToString("\n")
