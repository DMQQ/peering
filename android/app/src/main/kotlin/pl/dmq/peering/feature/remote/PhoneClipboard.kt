package pl.dmq.peering.feature.remote

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import pl.dmq.peering.session.clipboard.ClipboardContent

/** What the phone's clipboard holds, as far as the panel needs to say: nothing, text to send, a picture, or something else. */
sealed interface PhoneClip {
    data object Empty : PhoneClip

    data class Text(val text: String) : PhoneClip

    /** A picture the clipboard names by [uri]; its bytes are read only when the user sends it. */
    data class Image(val uri: Uri) : PhoneClip

    data object Other : PhoneClip
}

internal fun ClipboardManager.currentClip(context: Context): PhoneClip {
    val clip = primaryClip?.takeIf { it.itemCount > 0 } ?: return PhoneClip.Empty
    val item = clip.getItemAt(0)
    val uri = item.uri
    if (uri != null && clip.description.hasMimeType("image/*")) return PhoneClip.Image(uri)
    val text = item.coerceToText(context)?.toString().orEmpty()
    return when {
        text.isNotEmpty() -> PhoneClip.Text(text)
        else -> PhoneClip.Other
    }
}

internal fun ClipboardManager.copyText(label: String, text: String) {
    setPrimaryClip(ClipData.newPlainText(label, text))
}

internal fun ClipboardManager.copyImage(context: Context, label: String, uri: Uri) {
    setPrimaryClip(ClipData.newUri(context.contentResolver, label, uri))
}

/** Puts [content] on the phone clipboard; a picture goes through a content URI of the app shared cache. */
internal suspend fun ClipboardManager.copyContent(context: Context, label: String, content: ClipboardContent?) {
    when (content) {
        is ClipboardContent.Text -> copyText(label, content.text)
        is ClipboardContent.Image -> copyImage(context, label, ClipboardImages.share(context, content.png))
        null -> Unit
    }
}
