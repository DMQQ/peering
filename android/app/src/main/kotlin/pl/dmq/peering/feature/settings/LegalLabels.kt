package pl.dmq.peering.feature.settings

import androidx.annotation.StringRes
import pl.dmq.peering.R

@StringRes
internal fun LegalDocument.labelRes(): Int = when (this) {
    LegalDocument.Privacy -> R.string.settings_legal_privacy
    LegalDocument.Terms -> R.string.settings_legal_terms
    LegalDocument.OpenSource -> R.string.settings_legal_open_source
}

@StringRes
internal fun LegalDocument.bodyRes(): Int = when (this) {
    LegalDocument.Privacy -> R.string.legal_privacy_body
    LegalDocument.Terms -> R.string.legal_terms_body
    LegalDocument.OpenSource -> R.string.legal_open_source_body
}

/** The page on the web that carries the same document, or null for a document that only lives in the app. */
internal fun LegalDocument.webUrl(): String? = when (this) {
    LegalDocument.Privacy -> "https://getpeering.app/privacy"
    LegalDocument.Terms -> "https://getpeering.app/terms"
    LegalDocument.OpenSource -> null
}
