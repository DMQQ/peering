package pl.dmq.peering.feature.settings

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.ControlLink
import pl.dmq.peering.ui.kit.ControlRow
import pl.dmq.peering.ui.kit.ControlsCard
import pl.dmq.peering.ui.kit.ControlsDivider
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.SessionIcons
import pl.dmq.peering.ui.kit.englishDate
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes
import pl.dmq.peering.wire.ReferralCode
import pl.dmq.peering.wire.ReferralRefusal

private const val MILLIS_PER_SECOND = 1_000L

@Composable
internal fun InviteCard(
    state: InviteUiState,
    nowSeconds: Long,
    onRefresh: () -> Unit,
    onRedeem: (String) -> Unit,
    onShare: (String) -> Unit,
) {
    LaunchedEffect(Unit) { onRefresh() }
    var redeeming by rememberSaveable { mutableStateOf(false) }
    val referral = state.referral
    ControlsCard(stringResource(R.string.settings_invite_heading), footer = inviteFooterText(inviteFooter(referral, nowSeconds))) {
        if (referral != null) {
            ControlRow(stringResource(R.string.settings_invite_code), SessionIcons.ticket) {
                SelectionContainer {
                    Text(
                        ReferralCode.display(referral.code),
                        style = PeeringText.subheadlineSemibold.copy(fontFamily = FontFamily.Monospace),
                        color = PeeringColors.ink,
                    )
                }
            }
            ControlsDivider()
            val message = stringResource(R.string.settings_invite_message, ReferralCode.display(referral.code))
            ControlRow(
                stringResource(R.string.settings_invite_share),
                SessionIcons.share,
                Modifier.clip(peeringShapes.extraSmall).tappable({ onShare(message) }),
            )
        }
        if (referral?.redeemed != true) {
            if (referral != null) ControlsDivider()
            ControlLink(stringResource(R.string.settings_invite_enter), SessionIcons.gift, { redeeming = true })
        }
        state.failure?.let {
            Text(stringResource(it.messageRes()), style = PeeringText.caption, color = PeeringColors.danger)
        }
    }
    if (redeeming) {
        RedeemDialog(
            minutes = inviteBonusMinutes(referral),
            onRedeem = {
                redeeming = false
                onRedeem(it)
            },
            onDismiss = { redeeming = false },
        )
    }
}

@Composable
private fun RedeemDialog(minutes: Int, onRedeem: (String) -> Unit, onDismiss: () -> Unit) {
    var draft by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = PeeringColors.sheet,
        title = { Text(stringResource(R.string.settings_invite_enter)) },
        text = {
            Column {
                Text(stringResource(R.string.settings_invite_bonus, minutes, INVITE_BONUS_DAYS), color = PeeringColors.muted)
                Spacer(Modifier.height(16.dp))
                PeeringTextField(
                    draft,
                    { draft = it },
                    stringResource(R.string.settings_invite_hint),
                    Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false),
                    monospaced = true,
                )
            }
        },
        confirmButton = { TextButton(onClick = { onRedeem(draft) }) { Text(stringResource(R.string.settings_invite_redeem)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.settings_cancel)) } },
    )
}

@Composable
private fun inviteFooterText(footer: InviteFooter): String = when (footer) {
    InviteFooter.Send -> stringResource(R.string.settings_invite_footer)
    is InviteFooter.Running -> stringResource(
        R.string.settings_invite_footer_running,
        footer.minutes,
        englishDate(footer.endsAtSeconds * MILLIS_PER_SECOND),
        footer.earned,
        footer.max,
    )
    is InviteFooter.Idle -> stringResource(R.string.settings_invite_footer_idle, footer.earned, footer.max)
}

@StringRes
internal fun ReferralRefusal.messageRes(): Int = when (this) {
    ReferralRefusal.UnknownCode -> R.string.settings_invite_unknown
    ReferralRefusal.OwnCode -> R.string.settings_invite_own
    ReferralRefusal.AlreadyRedeemed -> R.string.settings_invite_already
    ReferralRefusal.NeedsKeyProof -> R.string.settings_invite_proof
    ReferralRefusal.Busy -> R.string.settings_invite_busy
    ReferralRefusal.NetworkLimit -> R.string.settings_invite_network_limit
    ReferralRefusal.Unavailable -> R.string.settings_invite_unavailable
}
