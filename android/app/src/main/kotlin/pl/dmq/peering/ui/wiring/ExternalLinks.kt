package pl.dmq.peering.ui.wiring

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import pl.dmq.peering.R

/** Opens [url] in the browser the phone has chosen. Without one, the user is told rather than left with nothing happening. */
internal fun Context.openWebPage(url: String) {
    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
    try {
        startActivity(intent)
    } catch (failure: ActivityNotFoundException) {
        Toast.makeText(this, R.string.legal_no_browser, Toast.LENGTH_LONG).show()
    }
}
