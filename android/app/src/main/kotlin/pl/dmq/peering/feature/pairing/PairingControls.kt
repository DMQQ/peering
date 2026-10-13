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
    unfocusedBorderColor = PeeringColors.ink.copy(alpha = 0.16f),
    errorBorderColor = PeeringColors.danger,
    errorSupportingTextColor = PeeringColors.danger,
    focusedPlaceholderColor = PeeringColors.faint,
    unfocusedPlaceholderColor = PeeringColors.faint,
    focusedContainerColor = PeeringColors.surface,
    unfocusedContainerColor = PeeringColors.surface,
    errorContainerColor = PeeringColors.surface,
)
