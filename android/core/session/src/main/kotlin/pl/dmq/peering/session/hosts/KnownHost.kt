package pl.dmq.peering.session.hosts

import kotlinx.serialization.Serializable
import pl.dmq.peering.session.history.SessionRecord

/** A Mac this device has paired with: the name it gave itself, and the route the last session to it took. */
@Serializable
data class KnownHost(val name: String, val lastPath: SessionRecord.Path)
