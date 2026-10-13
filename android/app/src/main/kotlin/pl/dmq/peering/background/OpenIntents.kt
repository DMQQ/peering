package pl.dmq.peering.background

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import pl.dmq.peering.MainActivity
import pl.dmq.peering.widget.LinkNonce
import pl.dmq.peering.widget.WidgetLink

/** The intents a notification sends back into the app. The link carries the install's nonce, like a widget tap. */
internal object OpenIntents {
    fun session(context: Context, hostId: String?): PendingIntent = open(context, WidgetLink.connect(hostId), REQUEST_SESSION)

    fun chat(context: Context, chatId: String, hostId: String?): PendingIntent =
        open(context, WidgetLink.chat(chatId, hostId), chatId.hashCode())

    private fun open(context: Context, link: String, requestCode: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(link))
            .setClass(context, MainActivity::class.java)
            .putExtra(LinkNonce.EXTRA, LinkNonce.load(context.noBackupFilesDir))
        return PendingIntent.getActivity(context, requestCode, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private const val REQUEST_SESSION = 1
}
