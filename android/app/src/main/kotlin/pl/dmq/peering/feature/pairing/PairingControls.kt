package pl.dmq.peering.feature.pairing

import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ButtonColors
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.Composable
import pl.dmq.peering.ui.theme.PeeringColors

/** The one filled control on a screen: white with a black label, as the Mac and iPhone draw it. */
@Composable
fun inkButtonColors(): ButtonColors = ButtonDefaults.buttonColors(
    containerColor = PeeringColors.ink,
    contentColor = PeeringColors.onInk,
    disabledContainerColor = PeeringColors.surface,
    disabledContentColor = PeeringColors.muted,
)

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
