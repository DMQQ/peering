package pl.dmq.peering.feature.ssh

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Backspace
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ssh.store.SshPasscodeStore
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

private val KEYS = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"), listOf("", "0", "<"))

/**
 * Six dots and a number pad. [onComplete] gets the digits when the sixth is typed. Giving [resetKey] a new value
 * clears the digits, so a wrong or mismatched entry starts clean.
 */
@Composable
internal fun PasscodePad(prompt: String, resetKey: Any?, onComplete: (String) -> Unit, modifier: Modifier = Modifier, error: String? = null) {
    var digits by remember(resetKey) { mutableStateOf("") }
    fun press(key: String) {
        if (key == "<") {
            digits = digits.dropLast(1)
            return
        }
        if (digits.length >= SshPasscodeStore.LENGTH) return
        digits += key
        if (digits.length == SshPasscodeStore.LENGTH) onComplete(digits)
    }
    Column(modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(prompt, style = PeeringText.subheadline, color = PeeringColors.muted, textAlign = TextAlign.Center)
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            repeat(SshPasscodeStore.LENGTH) { index ->
                Box(Modifier.size(12.dp).clip(CircleShape).background(if (index < digits.length) PeeringColors.ink else PeeringColors.outline))
            }
        }
        Text(error.orEmpty(), style = PeeringText.caption, color = PeeringColors.danger, modifier = Modifier.height(16.dp))
        KEYS.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                row.forEach { key -> Key(key, ::press) }
            }
        }
    }
}

@Composable
private fun Key(key: String, onPress: (String) -> Unit) {
    if (key.isEmpty()) return Spacer(Modifier.size(64.dp))
    val label = if (key == "<") stringResource(R.string.ssh_unlock_delete) else key
    Box(
        Modifier.size(64.dp).clip(CircleShape).background(PeeringColors.surface).tappable({ onPress(key) }),
        contentAlignment = Alignment.Center,
    ) {
        if (key == "<") {
            Icon(Icons.AutoMirrored.Outlined.Backspace, label, Modifier.size(22.dp), tint = PeeringColors.ink)
        } else {
            Text(key, style = PeeringText.title3, color = PeeringColors.ink)
        }
    }
}
