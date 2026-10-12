package pl.dmq.peering.feature.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

/** The first-run steps, one at a time. [onScanPairingCode] opens the camera scanner, which the app wires in. */
@Composable
fun OnboardingScreen(
    presenter: OnboardingPresenter,
    onScanPairingCode: () -> Unit,
    onOpenFaq: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ui by presenter.ui.collectAsState()
    Column(
        modifier = modifier.fillMaxSize().padding(horizontal = 18.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        StepDots(ui.stepNumber, ui.stepCount)
        OutlinedPanel(modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(stepTitle(ui.step)), style = MaterialTheme.typography.headlineSmall, color = PeeringColors.ink)
            Text(
                stringResource(stepBody(ui.step)),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.muted,
                modifier = Modifier.padding(top = 10.dp),
            )
            if (ui.step == OnboardingStep.SCAN_CODE) {
                Button(
                    onClick = onScanPairingCode,
                    modifier = Modifier.fillMaxWidth().padding(top = 16.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = PeeringColors.ink, contentColor = PeeringColors.onInk),
                ) {
                    Text(stringResource(R.string.onboarding_scan_button), style = MaterialTheme.typography.labelLarge)
                }
            }
        }
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
            if (ui.canGoBack) {
                OutlinedButton(onClick = presenter::back, modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.onboarding_back))
                }
            }
            Button(
                onClick = presenter::next,
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = PeeringColors.ink, contentColor = PeeringColors.onInk),
            ) {
                Text(stringResource(if (ui.isLastStep) R.string.onboarding_finish else R.string.onboarding_continue))
            }
        }
        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Text(
                stringResource(R.string.onboarding_skip),
                style = MaterialTheme.typography.labelLarge,
                color = PeeringColors.muted,
                modifier = Modifier.clickable(onClick = presenter::skip),
            )
            Text(
                stringResource(R.string.onboarding_questions),
                style = MaterialTheme.typography.labelLarge,
                color = PeeringColors.muted,
                modifier = Modifier.clickable(onClick = onOpenFaq),
            )
        }
    }
}

@Composable
private fun StepDots(current: Int, count: Int) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        repeat(count) { index ->
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(if (index + 1 == current) PeeringColors.ink else PeeringColors.faint),
            )
        }
    }
}

private fun stepTitle(step: OnboardingStep): Int = when (step) {
    OnboardingStep.WHAT_IS_PEERING -> R.string.onboarding_title_what
    OnboardingStep.INSTALL_HOST -> R.string.onboarding_title_install
    OnboardingStep.SCAN_CODE -> R.string.onboarding_title_scan
}

private fun stepBody(step: OnboardingStep): Int = when (step) {
    OnboardingStep.WHAT_IS_PEERING -> R.string.onboarding_body_what
    OnboardingStep.INSTALL_HOST -> R.string.onboarding_body_install
    OnboardingStep.SCAN_CODE -> R.string.onboarding_body_scan
}
