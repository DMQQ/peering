package pl.dmq.peering.feature.pairing

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

private const val SHAKE_STEP_MILLIS = 50
private const val WRONG_HOLD_MILLIS = 600L

/**
 * Six outlined cells over one invisible field, so the numeric keypad, paste and the one-time-code suggestion all land in
 * the same text. [onComplete] gets the digits the moment the sixth lands. A wrong answer ([attempts] rising with
 * [wrong]) shakes the row in the danger colour, then clears it for another try.
 */
@Composable
internal fun PairingCodeCells(
    attempts: Int,
    wrong: Boolean,
    onComplete: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var digits by rememberSaveable { mutableStateOf("") }
    var showsWrong by remember { mutableStateOf(false) }
    var focused by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    val shake = remember { Animatable(0f) }

    fun accept(input: String) {
        val next = pairingDigits(input)
        showsWrong = false
        digits = next
        if (next.length == PAIRING_CODE_LENGTH) onComplete(next)
    }

    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(attempts) {
        if (!wrong) return@LaunchedEffect
        showsWrong = true
        for (side in listOf(1f, -1f, 1f, -1f, 0f)) shake.animateTo(side * 10f, tween(SHAKE_STEP_MILLIS))
        delay(WRONG_HOLD_MILLIS)
        digits = ""
        showsWrong = false
        focus.requestFocus()
    }

    val label = stringResource(R.string.pairing_code_cells_label)
    Box(modifier = modifier.fillMaxWidth().offset(x = shake.value.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clearAndSetSemantics { contentDescription = label }
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                    focus.requestFocus()
                    keyboard?.show()
                },
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            repeat(PAIRING_CODE_LENGTH) { index ->
                val current = focused && !showsWrong && index == minOf(digits.length, PAIRING_CODE_LENGTH - 1)
                Cell(digits.getOrNull(index)?.toString().orEmpty(), current, showsWrong, Modifier.weight(1f))
            }
        }
        BasicTextField(
            value = digits,
            onValueChange = ::accept,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            textStyle = TextStyle(color = Color.Transparent),
            cursorBrush = SolidColor(Color.Transparent),
            modifier = Modifier
                .size(1.dp)
                .focusRequester(focus)
                .onFocusChanged { focused = it.isFocused },
        )
    }
}

@Composable
private fun Cell(text: String, current: Boolean, wrong: Boolean, modifier: Modifier) {
    val outline = when {
        wrong -> BorderStroke(1.5.dp, PeeringColors.danger)
        current -> BorderStroke(1.5.dp, PeeringColors.accent)
        else -> BorderStroke(1.dp, PeeringColors.ink.copy(alpha = 0.16f))
    }
    Box(
        modifier = modifier.height(64.dp).border(outline, MaterialTheme.shapes.small),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.headlineMedium.copy(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                fontSize = 28.sp,
            ),
            color = if (wrong) PeeringColors.danger else PeeringColors.ink,
        )
    }
}
