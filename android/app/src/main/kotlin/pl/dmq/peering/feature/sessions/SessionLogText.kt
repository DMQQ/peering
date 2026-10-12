package pl.dmq.peering.feature.sessions

import pl.dmq.peering.feature.files.fileSizeLabel
import pl.dmq.peering.session.history.SessionRecord

/** What "Copy session log" puts on the clipboard: the rows, then the log, so a transport line is never separated from its session. */
internal fun sessionLogText(record: SessionRecord, appVersion: String, startedLabel: String, nowMillis: Long): String {
    val lines = mutableListOf(
        "Peering session · ${record.hostName}",
        "App version: $appVersion",
        "Path: ${record.path.name.lowercase()}",
        "Started: $startedLabel",
        "Duration: ${durationLabel(record.durationSeconds(nowMillis))}",
        "Received: ${fileSizeLabel(record.bytesReceived)}",
        "Sent: ${fileSizeLabel(record.bytesSent)}",
        "",
    )
    lines += record.logs.ifEmpty { listOf("No diagnostic events were recorded for this session.") }
    return lines.joinToString("\n")
}
