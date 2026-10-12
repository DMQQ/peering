package pl.dmq.peering.ui.kit

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.dp

internal const val SYMBOL_STROKE = 1.7f

/** A 24 unit outline glyph drawn from SVG path data, stroked round like an SF Symbol at regular weight. [filled] paths are solid. */
internal fun symbol(name: String, vararg outline: String, filled: List<String> = emptyList(), stroke: Float = SYMBOL_STROKE): ImageVector {
    val builder = ImageVector.Builder(name = name, defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
    outline.forEach { data ->
        builder.addPath(
            pathData = PathParser().parsePathString(data).toNodes(),
            stroke = SolidColor(Color.Black),
            strokeLineWidth = stroke,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        )
    }
    filled.forEach { data ->
        builder.addPath(pathData = PathParser().parsePathString(data).toNodes(), fill = SolidColor(Color.Black))
    }
    return builder.build()
}
