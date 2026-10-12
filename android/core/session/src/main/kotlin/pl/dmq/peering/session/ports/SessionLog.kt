package pl.dmq.peering.session.ports

/** Where the session reports what it is doing, for a debug log. The app maps it to the platform log; the default drops it. */
fun interface SessionLog {
    fun log(message: String)

    companion object {
        val None = SessionLog { }
    }
}
