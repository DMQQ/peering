package pl.dmq.peering.feature.files

import pl.dmq.peering.wire.RemoteDirectoryEntry

private const val SECONDS_FROM_UNIX_EPOCH_TO_2001 = 978_307_200L
private const val MILLIS_PER_SECOND = 1000L

/** When the entry last changed as Unix milliseconds, or null when the computer did not say. The wire counts from 2001-01-01. */
fun RemoteDirectoryEntry.modifiedEpochMillis(): Long? =
    modified?.let { (it.toLong() + SECONDS_FROM_UNIX_EPOCH_TO_2001) * MILLIS_PER_SECOND }
