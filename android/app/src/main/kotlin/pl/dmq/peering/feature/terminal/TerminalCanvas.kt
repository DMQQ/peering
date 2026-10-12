package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.session.terminal.screen.ScreenSnapshot
import pl.dmq.peering.session.terminal.screen.StyledRun
import pl.dmq.peering.ui.theme.PeeringColors

private val cellStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp, lineHeight = 17.sp, color = PeeringColors.ink)
private const val DIM_ALPHA = 0.6f
private const val CURSOR_ALPHA = 0.6f
private const val WIDTH_SAMPLE = 20
private const val TEXT_CACHE = 512

/**
 * Draws a screen in monospaced text. It reports the grid that fits so the shell can be told, shows the tail of the
 * screen when there is more than fits (the cursor is at the bottom), and scrolls back through history on a vertical
 * drag. A tap is for the caller, which usually raises the keyboard.
 */
@Composable
fun TerminalCanvas(
    snapshot: ScreenSnapshot,
    onGrid: (columns: Int, rows: Int) -> Unit,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val measurer = rememberTextMeasurer(cacheSize = TEXT_CACHE)
    val cell = remember(measurer) {
        val measured = measurer.measure("M".repeat(WIDTH_SAMPLE), cellStyle).size
        Size(measured.width / WIDTH_SAMPLE.toFloat(), measured.height.toFloat())
    }
    var size by remember { mutableStateOf(IntSize.Zero) }
    var back by remember { mutableIntStateOf(0) }
    var dragged by remember { mutableFloatStateOf(0f) }
    val columns = (size.width / cell.width).toInt()
    val rows = (size.height / cell.height).toInt()

    LaunchedEffect(columns, rows) {
        if (columns > 0 && rows > 0) onGrid(columns, rows)
    }
    LaunchedEffect(snapshot.lines.size) { back = back.coerceAtMost((snapshot.lines.size - rows).coerceAtLeast(0)) }

    Canvas(
        modifier = modifier
            .fillMaxSize()
            .pointerInput(cell, snapshot.lines.size, rows) {
                val limit = (snapshot.lines.size - rows).coerceAtLeast(0)
                detectVerticalDragGestures { _, amount ->
                    dragged += amount
                    val lines = (dragged / cell.height).toInt()
                    if (lines != 0) {
                        dragged -= lines * cell.height
                        back = (back + lines).coerceIn(0, limit)
                    }
                }
            }
            .pointerInput(onTap) { detectTapGestures(onTap = { onTap() }) }
            .padding(horizontal = 8.dp)
            .onSizeChanged { size = it },
    ) {
        drawScreen(snapshot, measurer, cell, rows, back)
    }
}

private fun DrawScope.drawScreen(
    snapshot: ScreenSnapshot,
    measurer: TextMeasurer,
    cell: Size,
    rows: Int,
    back: Int,
) {
    val total = snapshot.lines.size
    val end = total - back
    val first = (end - rows).coerceAtLeast(0)
    for (index in first until end) {
        val y = (index - first) * cell.height
        var x = 0f
        for (run in snapshot.lines[index].runs) {
            val width = run.text.codePointCount(0, run.text.length) * cell.width
            drawRun(run, measurer, Offset(x, y), Size(width, cell.height))
            x += width
        }
    }
    val cursorRow = snapshot.cursorLine - first
    if (back == 0 && cursorRow in 0 until rows) {
        drawRect(
            PeeringColors.accent.copy(alpha = CURSOR_ALPHA),
            topLeft = Offset(snapshot.cursorColumn * cell.width, cursorRow * cell.height),
            size = cell,
        )
    }
}

private fun DrawScope.drawRun(
    run: StyledRun,
    measurer: TextMeasurer,
    at: Offset,
    box: Size,
) {
    val background = TerminalPalette.resolve(run.background, Color.Transparent)
    if (background != Color.Transparent) drawRect(background, topLeft = at, size = box)
    var color = TerminalPalette.resolve(run.foreground, PeeringColors.ink)
    if (run.dim) color = color.copy(alpha = DIM_ALPHA)
    val style = cellStyle.copy(color = color, fontWeight = if (run.bold) FontWeight.Bold else FontWeight.Normal)
    drawText(measurer, run.text, topLeft = at, style = style, softWrap = false)
}
