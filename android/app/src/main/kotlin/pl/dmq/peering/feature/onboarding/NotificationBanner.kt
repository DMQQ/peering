package pl.dmq.peering.feature.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.Image
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.ContinuousShape
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import androidx.compose.ui.draw.shadow

private data class Example(val title: Int, val body: Int, val age: Int?, val ageText: String?)

private val examples = listOf(
    Example(R.string.tour_notification_build_title, R.string.tour_notification_build_body, R.string.tour_notification_now, null),
    Example(R.string.tour_notification_password_title, R.string.tour_notification_password_body, null, "2m"),
    Example(R.string.tour_notification_answer_title, R.string.tour_notification_answer_body, null, "8m"),
)

/**
 * A lock screen drawn inside the tour's phone. Its type runs about a fifth larger than a real notification's: at the
 * tour's size an honest 13 point app name is seven points, and the weight that sets it apart from the title is lost.
 */
@Composable
internal fun NotificationBanner(modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        val width = maxWidth
        val height = maxHeight
        Image(painterResource(R.drawable.tour_wallpaper), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.04f), Color.Black.copy(alpha = 0.20f)))))
        Column(
            Modifier.fillMaxWidth().padding(top = height * 0.075f),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                stringResource(R.string.tour_notification_date),
                style = TextStyle(fontSize = (width * 0.045f).value.sp, fontWeight = FontWeight.SemiBold),
                color = Color.White,
            )
            Text(
                stringResource(R.string.tour_notification_time),
                style = PeeringText.display(size = (width * 0.30f).value, tracking = -(width * 0.01f).value, lineHeight = (width * 0.32f).value),
                color = Color.White,
            )
        }
        Column(
            Modifier.align(Alignment.BottomCenter).padding(bottom = height * 0.075f),
            verticalArrangement = Arrangement.spacedBy(width * 0.025f),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            examples.forEach { NotificationCard(it, width) }
        }
    }
}

@Composable
private fun NotificationCard(example: Example, width: Dp) {
    val shape = ContinuousShape(width * 0.055f)
    fun size(fraction: Float) = (width * fraction).value.sp
    Column(
        Modifier
            .width(width * 0.92f)
            .clip(shape)
            .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.09f), Color.White.copy(alpha = 0.045f))))
            .border(1.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.20f), Color.White.copy(alpha = 0.05f))), shape)
            .padding(horizontal = width * 0.035f, vertical = width * 0.023f),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val tile = width * 0.085f
            Box(
                Modifier.size(tile).background(PeeringColors.backdrop, ContinuousShape(tile * 0.2237f)),
                contentAlignment = Alignment.Center,
            ) {
                Image(painterResource(R.drawable.pears), null, Modifier.size(tile * 0.85f))
            }
            Spacer(Modifier.width(width * 0.025f))
            Text(stringResource(R.string.app_name), style = TextStyle(fontSize = size(0.038f), fontWeight = FontWeight.SemiBold), color = Color.White.copy(alpha = 0.70f), modifier = Modifier.weight(1f))
            Text(example.age?.let { stringResource(it) } ?: example.ageText.orEmpty(), style = TextStyle(fontSize = size(0.033f)), color = Color.White.copy(alpha = 0.55f))
        }
        Text(stringResource(example.title), style = TextStyle(fontSize = size(0.040f), fontWeight = FontWeight.SemiBold), color = Color.White, maxLines = 1, modifier = Modifier.padding(top = width * 0.014f))
        Text(
            stringResource(example.body),
            style = TextStyle(fontSize = size(0.033f)),
            color = Color.White.copy(alpha = 0.85f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = width * 0.003f),
        )
    }
}
