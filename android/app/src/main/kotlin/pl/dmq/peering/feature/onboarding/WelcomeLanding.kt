package pl.dmq.peering.feature.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.PrimaryButton
import pl.dmq.peering.ui.kit.pressable
import pl.dmq.peering.ui.kit.rememberSheen
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringMotion
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringBackdrop
import androidx.compose.animation.core.Animatable

/** The first screen for someone who has not decided yet: the product above the fold, one line of what it does, one way forward. */
@Composable
internal fun WelcomeLanding(onStart: () -> Unit, onSkip: () -> Unit, modifier: Modifier = Modifier) {
    val hero = remember { Animatable(0f) }
    val copy = remember { Animatable(0f) }
    val action = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        delay(60)
        hero.animateTo(1f, PeeringMotion.arrive)
    }
    LaunchedEffect(Unit) {
        delay(180)
        copy.animateTo(1f, PeeringMotion.arrive)
    }
    LaunchedEffect(Unit) {
        delay(300)
        action.animateTo(1f, PeeringMotion.arrive)
    }
    Box(modifier.fillMaxSize().peeringBackdrop()) {
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars).padding(top = 44.dp, bottom = 8.dp),
            verticalArrangement = Arrangement.spacedBy(28.dp),
        ) {
            WelcomeHero(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 22.dp)
                    .graphicsLayer {
                        alpha = hero.value
                        translationY = (1f - hero.value) * 28.dp.toPx()
                        scaleX = 0.96f + 0.04f * hero.value
                        scaleY = 0.96f + 0.04f * hero.value
                    },
            )
            Column(
                Modifier
                    .padding(horizontal = 22.dp)
                    .graphicsLayer { alpha = copy.value; translationY = (1f - copy.value) * 16.dp.toPx() },
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    stringResource(R.string.welcome_title),
                    style = PeeringText.display(size = 40f, tracking = -1.4f, lineHeight = 42f).copy(brush = rememberSheen()),
                )
                Text(stringResource(R.string.welcome_body), style = PeeringText.body, color = PeeringColors.muted)
            }
            Box(
                Modifier
                    .fillMaxWidth()
                    .background(PeeringColors.backdrop.copy(alpha = 0.92f))
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .padding(start = 22.dp, end = 22.dp, top = 14.dp, bottom = 18.dp)
                    .graphicsLayer { alpha = action.value },
            ) {
                PrimaryButton(stringResource(R.string.welcome_start), onStart)
            }
        }
        SkipButton(onSkip, Modifier.align(Alignment.TopEnd))
    }
}

@Composable
internal fun SkipButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Text(
        stringResource(R.string.tour_skip),
        style = PeeringText.footnote,
        color = PeeringColors.muted,
        modifier = modifier
            .windowInsetsPadding(WindowInsets.statusBars)
            .pressable(onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
    )
}
