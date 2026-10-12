package pl.dmq.peering.feature.pairing

import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.Composable
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
fun peeringFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = PeeringColors.ink,
    unfocusedTextColor = PeeringColors.ink,
    cursorColor = PeeringColors.ink,
    focusedBorderColor = PeeringColors.muted,
    unfocusedBorderColor = PeeringColors.hairline,
    errorBorderColor = PeeringColors.danger,
    errorSupportingTextColor = PeeringColors.danger,
    focusedPlaceholderColor = PeeringColors.faint,
    unfocusedPlaceholderColor = PeeringColors.faint,
    focusedContainerColor = PeeringColors.backdrop,
    unfocusedContainerColor = PeeringColors.backdrop,
    errorContainerColor = PeeringColors.backdrop,
)
