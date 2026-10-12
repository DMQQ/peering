package pl.dmq.peering.feature.agents

import pl.dmq.peering.session.files.UploadFailure

internal data class Uploading(val sessionID: String, val name: String)

internal data class FailedAttachment(val key: Long, val sessionID: String, val name: String, val reason: UploadFailure)

/** What the composer holds about attachments beyond the draft's paths: the file on its way, the ones that failed, and picture previews. */
internal data class AttachState(
    val uploading: Uploading? = null,
    val failed: List<FailedAttachment> = emptyList(),
    val thumbnails: Map<String, String> = emptyMap(),
    val nextKey: Long = 1,
)
