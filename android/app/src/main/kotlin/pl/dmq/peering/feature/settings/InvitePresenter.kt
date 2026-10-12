package pl.dmq.peering.feature.settings

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import pl.dmq.peering.session.relay.ReferralRefused
import pl.dmq.peering.wire.ReferralCode
import pl.dmq.peering.wire.ReferralRefusal
import pl.dmq.peering.wire.RelayReferral

/** What the Invite a friend card asks of the relay. */
interface InviteService {
    suspend fun status(): RelayReferral

    /** Throws [ReferralRefused] when the relay says no. */
    suspend fun redeem(typed: String): RelayReferral
}

data class InviteUiState(
    val referral: RelayReferral? = null,
    val failure: ReferralRefusal? = null,
)

class InvitePresenter(
    private val service: InviteService,
    private val scope: CoroutineScope,
) {
    private val mutableState = MutableStateFlow(InviteUiState())
    val state: StateFlow<InviteUiState> = mutableState.asStateFlow()

    /** Quiet on failure: the card keeps whatever it last knew, and a relay that is down is not news here. */
    fun refresh() {
        scope.launch {
            try {
                val standing = service.status()
                mutableState.update { it.copy(referral = standing) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (unreachable: Exception) {
                return@launch
            }
        }
    }

    fun redeem(typed: String) {
        if (!ReferralCode.isComplete(typed)) {
            mutableState.update { it.copy(failure = ReferralRefusal.UnknownCode) }
            return
        }
        scope.launch {
            try {
                val standing = service.redeem(typed)
                mutableState.update { InviteUiState(referral = standing) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (refused: ReferralRefused) {
                mutableState.update { it.copy(failure = refused.refusal) }
            } catch (unreachable: Exception) {
                mutableState.update { it.copy(failure = ReferralRefusal.Unavailable) }
            }
        }
    }
}

/** What the card's footer says, chosen from the relay's standing. */
sealed interface InviteFooter {
    data object Send : InviteFooter

    data class Running(val minutes: Int, val endsAtSeconds: Long, val earned: Int, val max: Int) : InviteFooter

    data class Idle(val earned: Int, val max: Int) : InviteFooter
}

fun inviteFooter(referral: RelayReferral?, nowSeconds: Long): InviteFooter {
    if (referral == null) return InviteFooter.Send
    val endsAt = referral.bonusEndsAt
    return if (endsAt != null && endsAt > nowSeconds) {
        InviteFooter.Running((referral.bonusSeconds / SECONDS_PER_MINUTE).toInt(), endsAt, referral.invitesEarned, referral.invitesMax)
    } else {
        InviteFooter.Idle(referral.invitesEarned, referral.invitesMax)
    }
}

/** The minutes a grant adds each day, for the redeem prompt: the standing's own figure once known, else the relay's usual 30. */
fun inviteBonusMinutes(referral: RelayReferral?): Int =
    referral?.bonusSeconds?.takeIf { it > 0 }?.let { (it / SECONDS_PER_MINUTE).toInt() } ?: DEFAULT_BONUS_MINUTES

const val INVITE_BONUS_DAYS = 7
private const val DEFAULT_BONUS_MINUTES = 30
private const val SECONDS_PER_MINUTE = 60L
