package pl.dmq.peering.feature.settings

import androidx.annotation.StringRes
import pl.dmq.peering.R
import pl.dmq.peering.feature.remote.InputMode
import pl.dmq.peering.feature.remote.KeyboardMode

@StringRes
internal fun StreamQuality.labelRes(): Int = when (this) {
    StreamQuality.Auto -> R.string.settings_quality_auto
    StreamQuality.Low -> R.string.settings_quality_low
    StreamQuality.Medium -> R.string.settings_quality_medium
    StreamQuality.High -> R.string.settings_quality_high
}

/** The menu's wording, which says what each level costs. */
@StringRes
internal fun StreamQuality.menuRes(): Int = when (this) {
    StreamQuality.Auto -> R.string.settings_quality_auto_menu
    StreamQuality.Low -> R.string.settings_quality_low_menu
    StreamQuality.Medium -> R.string.settings_quality_medium_menu
    StreamQuality.High -> R.string.settings_quality_high_menu
}

@StringRes
internal fun SettingsMessage.messageRes(): Int = when (this) {
    SettingsMessage.ForgetFailed -> R.string.settings_forget_failed
    SettingsMessage.QualitySaveFailed -> R.string.settings_quality_save_failed
    SettingsMessage.PreferenceSaveFailed -> R.string.settings_preference_save_failed
}

@StringRes
internal fun InputMode.labelRes(): Int = when (this) {
    InputMode.TRACKPAD -> R.string.settings_interaction_control
    InputMode.DIRECT -> R.string.settings_interaction_touch
    InputMode.OBSERVE -> R.string.settings_interaction_observe
}

@StringRes
internal fun KeyboardMode.labelRes(): Int = when (this) {
    KeyboardMode.UNICODE -> R.string.settings_keyboard_unicode
    KeyboardMode.KEYCODE -> R.string.settings_keyboard_keycode
}

@StringRes
internal fun KeyboardMode.explanationRes(): Int = when (this) {
    KeyboardMode.UNICODE -> R.string.settings_keyboard_unicode_explanation
    KeyboardMode.KEYCODE -> R.string.settings_keyboard_keycode_explanation
}
