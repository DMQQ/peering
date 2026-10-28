package pl.dmq.peering.ui.theme

import androidx.compose.foundation.background
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color

/** A few steps lighter than the theme's near-black so the tonal cards on it read softly instead of as holes. */
private val stage = Color(0xFF121214)

/** The stage every screen sits on: one flat tone, as Material's background is. */
fun Modifier.peeringBackdrop(): Modifier = background(stage)
