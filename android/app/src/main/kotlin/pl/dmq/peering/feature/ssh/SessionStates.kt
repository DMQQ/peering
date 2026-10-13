package pl.dmq.peering.feature.ssh

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ssh.model.SshAuthMethod
import pl.dmq.peering.ssh.session.SshPhase
import pl.dmq.peering.ssh.transport.SshFailure
import pl.dmq.peering.ui.kit.PeeringSpinner
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.QuietButton
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

@Composable
internal fun SegmentChip(title: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        title,
        style = PeeringText.subheadlineMedium,
        color = if (selected) PeeringColors.onInk else PeeringColors.ink,
        modifier = Modifier.clip(CircleShape)
            .background(if (selected) PeeringColors.ink else PeeringColors.surface)
            .tappable(onClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
    )
}

@Composable
internal fun Connecting(name: String, onCancel: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        PeeringSpinner()
        Text(stringResource(R.string.ssh_connecting, name), style = PeeringText.subheadline, color = PeeringColors.muted, modifier = Modifier.padding(vertical = 14.dp))
        QuietButton(onCancel) { Text(stringResource(R.string.ssh_cancel_connecting)) }
    }
}

/** The connection ended before a shell ever showed: the reason, and the two things to do about it. */
@Composable
internal fun EndedCard(ended: SshPhase.Ended, method: SshAuthMethod, onReconnect: () -> Unit, onClose: () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        val failure = ended.failure
        if (failure is SshFailure.HostKeyChanged) {
            ChangedKeyCard(failure)
        } else {
            Text(failure?.let { failureText(it, method) } ?: stringResource(R.string.ssh_fail_ended), style = PeeringText.body, color = PeeringColors.danger)
        }
        if (failure !is SshFailure.HostKeyChanged) PrimaryButton(stringResource(R.string.ssh_reconnect), onReconnect, Modifier.height(44.dp))
        QuietButton(onClose, Modifier.fillMaxWidth().height(44.dp)) { Text(stringResource(R.string.ssh_close)) }
    }
}

/** A connection that was working and stopped: the shells stay readable beneath this. */
@Composable
internal fun EndedBanner(ended: SshPhase.Ended, method: SshAuthMethod, onReconnect: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp).background(PeeringColors.containerHigh, peeringShapes.large).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            ended.failure?.let { failureText(it, method) } ?: stringResource(R.string.ssh_fail_ended),
            style = PeeringText.caption, color = PeeringColors.muted, modifier = Modifier.weight(1f),
        )
        Text(stringResource(R.string.ssh_reconnect), style = PeeringText.captionSemibold, color = PeeringColors.accent, modifier = Modifier.tappable(onReconnect).padding(6.dp))
    }
}

/**
 * The hard stop. There is no Trust here, and no button that carries on: the only way past is the server's menu, so a
 * hurried tap cannot turn the check into a formality.
 */
@Composable
internal fun ChangedKeyCard(failure: SshFailure.HostKeyChanged) {
    val mono = PeeringText.caption.copy(fontFamily = FontFamily.Monospace)
    Column(
        Modifier.fillMaxWidth().border(BorderStroke(1.dp, PeeringColors.danger), peeringShapes.large).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(stringResource(R.string.ssh_changed_title), style = PeeringText.headline, color = PeeringColors.danger)
        Text(stringResource(R.string.ssh_changed_body), style = PeeringText.subheadline, color = PeeringColors.ink)
        Text(stringResource(R.string.ssh_changed_known, failure.known.algorithm, failure.known.fingerprint), style = mono, color = PeeringColors.muted)
        Text(stringResource(R.string.ssh_changed_offered, failure.presented.algorithm, failure.presented.fingerprint), style = mono, color = PeeringColors.muted)
        Text(stringResource(R.string.ssh_changed_help), style = PeeringText.caption, color = PeeringColors.muted)
    }
}
