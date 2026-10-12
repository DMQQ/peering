package pl.dmq.peering.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

fun peeringColorScheme() = with(PeeringColors) {
    darkColorScheme(
        primary = ink,
        onPrimary = onInk,
        primaryContainer = selectedIndicator,
        onPrimaryContainer = ink,
        secondary = muted,
        onSecondary = onInk,
        secondaryContainer = selectedIndicator,
        onSecondaryContainer = ink,
        tertiary = accent,
        onTertiary = onInk,
        tertiaryContainer = surface,
        onTertiaryContainer = ink,
        background = backdrop,
        onBackground = ink,
        surface = backdrop,
        onSurface = ink,
        surfaceVariant = surface,
        onSurfaceVariant = muted,
        surfaceDim = backdrop,
        surfaceBright = containerHighest,
        surfaceContainerLowest = backdrop,
        surfaceContainerLow = sheet,
        surfaceContainer = container,
        surfaceContainerHigh = containerHigh,
        surfaceContainerHighest = containerHighest,
        inverseSurface = ink,
        inverseOnSurface = onInk,
        outline = outline,
        outlineVariant = hairline,
        error = danger,
        onError = onInk,
        errorContainer = surface,
        onErrorContainer = danger,
    )
}

@Composable
fun PeeringTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = peeringColorScheme(),
        typography = peeringTypography,
        shapes = peeringShapes,
        content = content,
    )
}
