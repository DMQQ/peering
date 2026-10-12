package pl.dmq.peering.feature.remote

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context

/** What the phone's clipboard holds, as far as the panel needs to say: nothing, text to send, or something else. */
sealed interface PhoneClip {
    data object Empty : PhoneClip

    data class Text(val text: String) : PhoneClip

    data object Other : PhoneClip
}

internal fun ClipboardManager.currentClip(context: Context): PhoneClip {
    val clip = primaryClip?.takeIf { it.itemCount > 0 } ?: return PhoneClip.Empty
    val text = clip.getItemAt(0).coerceToText(context)?.toString().orEmpty()
    return when {
        text.isNotEmpty() -> PhoneClip.Text(text)
        else -> PhoneClip.Other
    }
}

internal fun ClipboardManager.copyText(label: String, text: String) {
    setPrimaryClip(ClipData.newPlainText(label, text))
}
