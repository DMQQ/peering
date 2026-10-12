package pl.dmq.peering.feature.settings

data class SettingsUiState(
    val trustedHosts: List<TrustedHost> = emptyList(),
    /** The trusted Mac the user has asked to forget, awaiting confirmation. */
    val forgetTarget: TrustedHost? = null,
    val streamQuality: StreamQuality = StreamQuality.Auto,
    val message: SettingsMessage? = null,
    val appVersion: String = "",
)
