package pl.dmq.peering.feature.settings

import androidx.annotation.StringRes
import pl.dmq.peering.R

@StringRes
internal fun StreamQuality.labelRes(): Int = when (this) {
    StreamQuality.Auto -> R.string.settings_quality_auto
    StreamQuality.Low -> R.string.settings_quality_low
    StreamQuality.Medium -> R.string.settings_quality_medium
    StreamQuality.High -> R.string.settings_quality_high
}

@StringRes
internal fun SettingsMessage.messageRes(): Int = when (this) {
    SettingsMessage.ForgetFailed -> R.string.settings_forget_failed
    SettingsMessage.ResetFailed -> R.string.settings_identity_reset_failed
    SettingsMessage.ResetDone -> R.string.settings_identity_reset_done
    SettingsMessage.QualitySaveFailed -> R.string.settings_quality_save_failed
}
