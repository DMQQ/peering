package pl.dmq.peering.feature.pairing

import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
import pl.dmq.peering.session.controller.PairingCodeError
import pl.dmq.peering.ui.theme.PeeringTheme

private fun ignore() = Unit

@Suppress("UNUSED_PARAMETER")
private fun ignore(digits: String) = Unit

private val previewActions = PairingActions(
    onDigitsEntered = ::ignore,
    onCancel = ::ignore,
    onFinished = ::ignore,
    onScan = ::ignore,
)

@Composable
private fun Frame(screen: PairingCodeScreen) {
    PeeringTheme { PairingCodeContent(screen, previewActions) }
}

@Preview(name = "Pairing, found and connecting", showBackground = true, heightDp = 800)
@Composable
private fun PairingConnectingPreview() = Frame(PairingCodeScreen.Connecting)

@Preview(name = "Pairing, enter the code", showBackground = true, heightDp = 800)
@Composable
private fun PairingEnterCodePreview() = Frame(PairingCodeScreen.EnteringCode(0, null))

@Preview(name = "Pairing, wrong code", showBackground = true, heightDp = 800)
@Composable
private fun PairingWrongCodePreview() = Frame(PairingCodeScreen.EnteringCode(1, PairingCodeError.WrongCode))

@Preview(name = "Pairing, approve on the computer", showBackground = true, heightDp = 800)
@Composable
private fun PairingApprovePreview() = Frame(PairingCodeScreen.Waiting)

@Preview(name = "Pairing, connected", showBackground = true, heightDp = 800)
@Composable
private fun PairingConnectedPreview() = Frame(PairingCodeScreen.Done)

@Preview(name = "Pairing, failed", showBackground = true, heightDp = 800)
@Composable
private fun PairingFailedPreview() = Frame(PairingCodeScreen.Failed(PairingMessage.TooManyAttempts))
