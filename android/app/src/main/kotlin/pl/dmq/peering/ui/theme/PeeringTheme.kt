package pl.dmq.peering.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

fun peeringColorScheme() = with(PeeringColors) {
    darkColorScheme(
        primary = ink,
        onPrimary = onInk,
        primaryContainer = surface,
        onPrimaryContainer = ink,
        secondary = muted,
        onSecondary = onInk,
        secondaryContainer = surface,
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
        surfaceBright = surface,
        surfaceContainerLowest = backdrop,
        surfaceContainerLow = backdrop,
        surfaceContainer = backdrop,
        surfaceContainerHigh = surface,
        surfaceContainerHighest = surface,
        inverseSurface = ink,
        inverseOnSurface = onInk,
        outline = hairline,
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
