package pl.dmq.peering.background

/** What to do about the notification permission, decided without Android so it can be tested. */
internal enum class PermissionStep {
    None,

    /** Say why first, then ask: the first session, when the user has just seen what the app does. */
    ExplainThenAsk,

    Ask,

    /** The system no longer shows its dialog after a refusal; only the app's notification settings can change it. */
    OpenSettings,
}

internal object PermissionPrompt {
    /** The permission exists from Android 13; earlier versions allow notifications unless the user blocked the app. */
    const val FIRST_SDK_WITH_PERMISSION = 33

    fun onFirstSession(sdk: Int, granted: Boolean, enabled: Boolean, explainedBefore: Boolean): PermissionStep =
        if (sdk < FIRST_SDK_WITH_PERMISSION || granted || !enabled || explainedBefore) PermissionStep.None else PermissionStep.ExplainThenAsk

    fun onToggledOn(sdk: Int, granted: Boolean, refusedBefore: Boolean): PermissionStep = when {
        sdk < FIRST_SDK_WITH_PERMISSION || granted -> PermissionStep.None
        refusedBefore -> PermissionStep.OpenSettings
        else -> PermissionStep.Ask
    }
}
