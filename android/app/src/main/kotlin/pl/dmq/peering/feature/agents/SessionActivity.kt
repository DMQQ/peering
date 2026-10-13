package pl.dmq.peering.feature.agents

import pl.dmq.peering.session.agent.AgentChatSession
import pl.dmq.peering.session.ports.Clock

/**
 * The time each chat last moved, as the phone saw it. A chat first seen is dated from its creation on the Mac; after
 * that the date moves whenever its event index advances. Mutated only from the presenter's own scope.
 */
internal class SessionActivity(private val clock: Clock) {
    private class Mark(val index: Long, val unixSeconds: Long)

    private val marks = mutableMapOf<String, Mark>()

    fun lastActivityUnix(session: AgentChatSession): Long {
        val index = maxOf(session.info.lastIndex, session.transcript.lastIndex)
        val known = marks[session.id]
        if (known == null) {
            val created = session.info.createdAt.toLong() + APPLE_EPOCH_OFFSET_SECONDS
            marks[session.id] = Mark(index, created)
            return created
        }
        if (index <= known.index) return known.unixSeconds
        val now = clock.unixSeconds()
        marks[session.id] = Mark(index, now)
        return now
    }

    fun forget(sessionIDs: Set<String>) {
        marks.keys.retainAll(sessionIDs)
    }

    private companion object {
        /** Seconds from 1970-01-01 to 2001-01-01, the reference the Mac's dates count from. */
        const val APPLE_EPOCH_OFFSET_SECONDS = 978_307_200L
    }
}
