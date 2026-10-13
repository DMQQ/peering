package pl.dmq.peering.feature.whatsnew

import androidx.annotation.StringRes
import androidx.compose.ui.graphics.vector.ImageVector
import pl.dmq.peering.R
import pl.dmq.peering.session.ports.KeyValueStore
import pl.dmq.peering.ui.kit.AppIcons

/** What the What's New sheet does at launch. The release text lives in resources; only its id is compared here. */
object WhatsNewPolicy {
    enum class Decision {
        Show,

        /** Nothing to present, but the release is recorded so it is not shown later as news. */
        RecordWithoutShowing,
        Nothing,
    }

    /**
     * A first-time user has not met the previous version, so the sheet would describe changes to something they never
     * used: the release is recorded and the tour does the introducing.
     */
    fun decide(currentRelease: String?, lastSeenRelease: String?, hasFinishedFirstRun: Boolean): Decision {
        if (currentRelease == null || currentRelease == lastSeenRelease) return Decision.Nothing
        return if (hasFinishedFirstRun) Decision.Show else Decision.RecordWithoutShowing
    }
}

/**
 * The improvements the sheet announces. Change [id] and the items together when there is something new to say: people who
 * have seen the old id are shown the sheet once more.
 */
class WhatsNewRelease(val id: String, val items: List<Item>) {
    class Item(val icon: ImageVector, @StringRes val title: Int, @StringRes val detail: Int)

    companion object {
        val current: WhatsNewRelease? = WhatsNewRelease(
            id = "2026-10-13",
            items = listOf(
                Item(AppIcons.spaces, R.string.whatsnew_desktops_title, R.string.whatsnew_desktops_detail),
                Item(AppIcons.command, R.string.whatsnew_composer_title, R.string.whatsnew_composer_detail),
                Item(AppIcons.checkCircle, R.string.whatsnew_review_title, R.string.whatsnew_review_detail),
                Item(AppIcons.power, R.string.whatsnew_wake_title, R.string.whatsnew_wake_detail),
            ),
        )
    }
}

/** The id of the release the person was last shown, kept so the sheet appears once per release. */
class WhatsNewStore(private val store: KeyValueStore) {
    fun lastSeen(): String? = store.read(KEY)?.takeIf { it.isNotEmpty() }

    fun record(releaseId: String) = store.write(KEY, releaseId)

    private companion object {
        const val KEY = "last_seen_whats_new"
    }
}
