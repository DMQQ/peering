package pl.dmq.peering.platform.identity

import java.util.Locale
import java.util.UUID
import pl.dmq.peering.session.ports.SecretStore
import pl.dmq.peering.session.ports.StoredRead

private const val CLIENT_ID_KEY = "pl.dmq.peering.clientId"

internal object ClientIds {
    /**
     * The stored id, or a new one when none exists. When the stored id exists but cannot be read for a passing reason it
     * is left alone and this run uses a fresh id that is not saved, so the real one comes back on the next launch.
     */
    fun resolve(secrets: SecretStore): String {
        val result = secrets.read(CLIENT_ID_KEY)
        if (result is StoredRead.Found) {
            result.bytes.toString(Charsets.UTF_8).takeIf { it.isNotEmpty() }?.let { return it }
        }
        val id = UUID.randomUUID().toString().uppercase(Locale.ROOT)
        val mayStore = result !is StoredRead.Unreadable || result.permanent
        if (mayStore) secrets.put(CLIENT_ID_KEY, id.toByteArray(Charsets.UTF_8))
        return id
    }
}
