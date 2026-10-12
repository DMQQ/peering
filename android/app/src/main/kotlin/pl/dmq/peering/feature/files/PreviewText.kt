package pl.dmq.peering.feature.files

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors

@Composable
fun TextPreviewView(content: PreviewContent.Text, wraps: Boolean, modifier: Modifier = Modifier) {
    val mono = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
    val digits = content.lines.size.toString().length
    Column(modifier = modifier.fillMaxSize()) {
        TruncationNote(content.isTruncated, content.shownBytes, content.totalBytes)
        LazyColumn(
            modifier = Modifier.fillMaxSize().let { if (wraps) it else it.horizontalScroll(rememberScrollState()) },
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        ) {
            itemsIndexed(content.lines) { index, line ->
                Row {
                    if (content.showsLineNumbers) {
                        Text((index + 1).toString().padStart(digits) + "  ", style = mono, color = PeeringColors.tertiary)
                    }
                    Text(line, style = mono, color = PeeringColors.ink, softWrap = wraps)
                }
            }
        }
    }
}

@Composable
fun MarkdownPreviewView(content: PreviewContent.Markdown, modifier: Modifier = Modifier) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item { TruncationNote(content.isTruncated, content.shownBytes, content.totalBytes) }
        itemsIndexed(content.blocks) { _, block -> MarkdownBlockView(block) }
    }
}

@Composable
private fun TruncationNote(isTruncated: Boolean, shown: Long, total: Long) {
    if (!isTruncated) return
    Text(
        stringResource(R.string.preview_truncated, fileSizeLabel(shown), fileSizeLabel(total)),
        style = MaterialTheme.typography.bodySmall,
        color = PeeringColors.caution,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
private fun MarkdownBlockView(block: MarkdownBlock) {
    when (block) {
        is MarkdownBlock.Heading -> Text(
            inline(block.text),
            style = when (block.level) {
                1 -> MaterialTheme.typography.headlineSmall
                2 -> MaterialTheme.typography.titleLarge
                else -> MaterialTheme.typography.titleMedium
            },
            color = PeeringColors.ink,
        )
        is MarkdownBlock.Paragraph -> Text(inline(block.text), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.ink)
        is MarkdownBlock.Bullet -> ListLine("•", block.text, block.depth)
        is MarkdownBlock.Numbered -> ListLine("${block.number}.", block.text, block.depth)
        is MarkdownBlock.Quote -> Text(
            inline(block.text),
            style = MaterialTheme.typography.bodyMedium,
            color = PeeringColors.muted,
            modifier = Modifier.fillMaxWidth().background(PeeringColors.surface, MaterialTheme.shapes.medium).padding(12.dp),
        )
        is MarkdownBlock.Code -> Text(
            block.text,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            color = PeeringColors.ink,
            modifier = Modifier
                .fillMaxWidth()
                .background(PeeringColors.containerHigh, MaterialTheme.shapes.medium)
                .horizontalScroll(rememberScrollState())
                .padding(12.dp),
            softWrap = false,
        )
        MarkdownBlock.Rule -> HorizontalDivider(color = PeeringColors.hairline)
    }
}

@Composable
private fun ListLine(marker: String, text: String, depth: Int) {
    Row(modifier = Modifier.padding(start = (depth * 16).dp)) {
        Text(marker + " ", style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
        Text(inline(text), style = MaterialTheme.typography.bodyMedium, color = PeeringColors.ink)
    }
}

private fun inline(text: String) = buildAnnotatedString {
    MarkdownSpans.parse(text).forEach { span ->
        val style = when (span.style) {
            MarkdownSpan.Style.PLAIN -> SpanStyle()
            MarkdownSpan.Style.BOLD -> SpanStyle(fontWeight = FontWeight.Bold)
            MarkdownSpan.Style.ITALIC -> SpanStyle(fontStyle = FontStyle.Italic)
            MarkdownSpan.Style.CODE -> SpanStyle(fontFamily = FontFamily.Monospace, background = PeeringColors.containerHighest)
        }
        withStyle(style) { append(span.text) }
    }
}
