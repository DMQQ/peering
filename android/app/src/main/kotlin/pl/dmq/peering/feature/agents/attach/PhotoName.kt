package pl.dmq.peering.feature.agents.attach

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** The name a picked photo is sent under: the time it was picked, so two photos never share a name. */
object PhotoName {
    private val stamp = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss")

    fun of(epochMillis: Long, zone: ZoneId = ZoneId.systemDefault()): String =
        "Photo-" + stamp.withZone(zone).format(Instant.ofEpochMilli(epochMillis)) + ".jpg"
}
