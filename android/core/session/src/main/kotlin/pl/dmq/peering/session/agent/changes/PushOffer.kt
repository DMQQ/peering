package pl.dmq.peering.session.agent.changes

import pl.dmq.peering.wire.AgentGitBranch

/** What the push step should offer: the push the phone could ask for, or why it cannot. */
sealed interface PushOffer {
    data class Ready(val branch: String, val upstream: String, val ahead: Int) : PushOffer

    data object NothingToPush : PushOffer

    data class Blocked(val reason: PushBlock) : PushOffer

    companion object {
        /** Mirrors the computer's own refusals, so the phone does not offer a push the computer would turn down. */
        fun of(branch: AgentGitBranch?): PushOffer {
            if (branch == null) return Blocked(PushBlock.UNREADABLE)
            val head = branch.head ?: return Blocked(PushBlock.DETACHED_HEAD)
            val upstream = branch.upstream
            if (upstream == null || branch.remote.isNullOrBlank() || branch.mergeRef.isNullOrBlank()) {
                return Blocked(PushBlock.NO_UPSTREAM)
            }
            return if (branch.ahead > 0) Ready(head, upstream, branch.ahead) else NothingToPush
        }
    }
}

enum class PushBlock { UNREADABLE, DETACHED_HEAD, NO_UPSTREAM }
