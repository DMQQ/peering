package pl.dmq.peering.widget

/**
 * What a `peering://` link from outside the app may do. Any page or app can open one, so nothing runs behind the app
 * lock, and ending a live session asks a person first. A link held for the lock waits for the unlock; locking drops a
 * pending question, so a dialog left on screen cannot be accepted behind the lock.
 */
class ExternalLinkGate {
    /** Starts locked, so a link that launches the app cannot beat the lock before the activity says otherwise. */
    var isLocked: Boolean = true
        private set

    /** The ending link waiting for an answer; the dialog reads it. */
    var confirming: WidgetLink? = null
        private set

    private var held: WidgetLink? = null

    /** The link to run now, or null when it is held for the lock or waits for an answer. */
    fun submit(link: WidgetLink, hasLiveSession: Boolean): WidgetLink? {
        if (isLocked) {
            held = link
            return null
        }
        if (link is WidgetLink.Disconnect && hasLiveSession) {
            confirming = link
            return null
        }
        return link
    }

    /** A link held while locked, to be submitted again now that the lock is open. */
    fun setLocked(locked: Boolean): WidgetLink? {
        isLocked = locked
        if (locked) {
            confirming = null
            return null
        }
        return held.also { held = null }
    }

    /** The confirmed link, or null when none waits or the lock came up meanwhile. */
    fun confirm(): WidgetLink? = (if (isLocked) null else confirming).also { confirming = null }

    fun cancelConfirmation() {
        confirming = null
    }
}
