package pl.dmq.peering.feature.connect

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PeeringSheet
import pl.dmq.peering.ui.kit.PeeringTextField
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

/** Dials a computer by its address and port, for a network where it cannot be found by name. */
@Composable
internal fun ManualAddressSheet(onConnect: (host: String, port: String) -> Unit, onDismiss: () -> Unit) {
    var host by rememberSaveable { mutableStateOf("") }
    var port by rememberSaveable { mutableStateOf(ManualAddress.DEFAULT_PORT.toString()) }
    val valid = ManualAddress.parse(host, port) != null
    PeeringSheet(onDismiss) {
        Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 24.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Text(stringResource(R.string.connect_address_title), style = MaterialTheme.typography.headlineMedium, color = PeeringColors.ink)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PeeringTextField(
                    host, { host = it }, stringResource(R.string.connect_address_hint), Modifier.weight(1f),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                )
                PeeringTextField(
                    port, { port = it.filter(Char::isDigit) }, stringResource(R.string.connect_port_hint), Modifier.width(88.dp),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { if (valid) onConnect(host, port) }),
                )
            }
            PrimaryButton(stringResource(R.string.connect_address_connect), onClick = { onConnect(host, port) }, enabled = valid)
        }
    }
}
