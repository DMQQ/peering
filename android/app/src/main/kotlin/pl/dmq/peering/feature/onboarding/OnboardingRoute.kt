package pl.dmq.peering.feature.onboarding

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier

/**
 * The first run and its questions. [onFinished] runs once the user finishes or skips the steps, after the store has
 * recorded it; the caller then shows the rest of the app.
 */
@Composable
fun OnboardingRoute(
    store: FirstRunStore,
    onScanPairingCode: () -> Unit,
    onFinished: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val presenter = remember(store) { OnboardingPresenter(store) }
    val ui by presenter.ui.collectAsState()
    var showingFaq by remember { mutableStateOf(false) }
    LaunchedEffect(ui.completed) {
        if (ui.completed) onFinished()
    }
    Surface(modifier = modifier, color = MaterialTheme.colorScheme.background) {
        when {
            showingFaq -> FaqScreen(onBack = { showingFaq = false })
            else -> OnboardingScreen(
                presenter = presenter,
                onScanPairingCode = onScanPairingCode,
                onOpenFaq = { showingFaq = true },
            )
        }
    }
}
