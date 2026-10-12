package pl.dmq.peering.feature.settings

import androidx.annotation.StringRes
import pl.dmq.peering.R

@StringRes
internal fun LegalDocument.labelRes(): Int = when (this) {
    LegalDocument.Privacy -> R.string.settings_legal_privacy
    LegalDocument.Terms -> R.string.settings_legal_terms
}
