package pl.dmq.peering.session.controller

/** The stream quality the user chose, and whether this phone has unlimited relay time. Read when a session starts and when the quality changes. */
interface QualitySource {
    fun choice(): QualityChoice

    fun unlimitedRelay(): Boolean

    /** Whether the phone asks apps to use less power: battery saver, or a device running hot. The picture is then held lower. */
    fun powerSaving(): Boolean = false

    companion object {
        /** Automatic, with relayed sessions held to Medium: what a phone with no stored choice and no paid relay time streams. */
        val Default: QualitySource = object : QualitySource {
            override fun choice(): QualityChoice = QualityChoice.Automatic

            override fun unlimitedRelay(): Boolean = false
        }
    }
}
