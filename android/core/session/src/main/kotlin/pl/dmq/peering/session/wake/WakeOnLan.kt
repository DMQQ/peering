package pl.dmq.peering.session.wake

/** The magic packet that wakes a sleeping computer on the local network: six 0xFF bytes, then its hardware address sixteen times. */
object WakeOnLan {
    /** Port 9 is the usual one and port 7 the fallback; the packet is sent to both. */
    val PORTS = listOf(9, 7)

    private const val OCTETS = 6
    private const val REPEATS = 16

    /** The packet for [mac] written `aa:bb:cc:dd:ee:ff`, or null when it is not six pairs of hex digits. */
    fun magicPacket(mac: String): ByteArray? {
        val fields = mac.split(':')
        if (fields.size != OCTETS || fields.any { it.length != 2 || !it.all { c -> isHex(c) } }) return null
        val octets = fields.map { it.toInt(16).toByte() }
        return ByteArray(OCTETS) { 0xFF.toByte() } + (0 until REPEATS).flatMap { octets }.toByteArray()
    }

    private fun isHex(c: Char): Boolean = c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F'
}
