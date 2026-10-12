package pl.dmq.peering.feature.agents.preview

import android.content.res.Resources
import androidx.annotation.StringRes
import pl.dmq.peering.R
import pl.dmq.peering.wire.PreviewFailure

/** The words of the plain-text replies the web view shows when a request could not be carried. */
interface PreviewTexts {
    fun failure(reason: PreviewFailure): String

    fun dataNotCarried(): String
}

internal class ResourcePreviewTexts(private val resources: Resources) : PreviewTexts {
    override fun failure(reason: PreviewFailure): String = resources.getString(previewFailureDetail(reason))

    override fun dataNotCarried(): String = resources.getString(R.string.preview_reply_not_carried)
}

@StringRes
internal fun previewFailureDetail(failure: PreviewFailure?): Int = when (failure) {
    PreviewFailure.NOT_LISTENING -> R.string.preview_fail_not_listening_detail
    PreviewFailure.DISCONNECTED -> R.string.preview_fail_disconnected_detail
    PreviewFailure.TIMED_OUT -> R.string.preview_fail_timed_out_detail
    PreviewFailure.TOO_LARGE -> R.string.preview_fail_too_large_detail
    PreviewFailure.NOT_ALLOWED, PreviewFailure.INVALID_REQUEST -> R.string.preview_fail_not_allowed_detail
    PreviewFailure.BUSY -> R.string.preview_fail_busy_detail
    PreviewFailure.FAILED, null -> R.string.preview_fail_failed_detail
}
