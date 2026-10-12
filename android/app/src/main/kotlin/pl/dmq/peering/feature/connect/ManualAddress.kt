package pl.dmq.peering.feature.connect

/** A computer dialled by address when it cannot be found by name. */
data class ManualAddress(val host: String, val port: Int) {
    companion object {
        const val DEFAULT_PORT = 51515

        /** The typed fields as an address, or null while they are not one. An empty port means [DEFAULT_PORT]. */
        fun parse(host: String, port: String): ManualAddress? {
            val name = host.trim()
            if (name.isEmpty() || name.any(Char::isWhitespace)) return null
            val digits = port.trim()
            val number = if (digits.isEmpty()) DEFAULT_PORT else digits.toIntOrNull() ?: return null
            if (number !in 1..65535) return null
            return ManualAddress(name, number)
        }
    }
}
