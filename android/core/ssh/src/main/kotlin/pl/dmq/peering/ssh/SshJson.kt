package pl.dmq.peering.ssh

import kotlinx.serialization.json.Json

/** Lenient on read so a blob written by a newer build still opens, and an unknown enum value falls back to its default. */
internal val SshJson = Json {
    ignoreUnknownKeys = true
    coerceInputValues = true
    encodeDefaults = true
}
