package pl.dmq.peering.feature.agents.review

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.changes.DiffCounts
import pl.dmq.peering.session.agent.changes.ReviewFile
import pl.dmq.peering.session.agent.changes.ReviewQueue
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.hubCardSurface
import pl.dmq.peering.ui.kit.tappable
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

private const val PREVIEW_COUNT = 3

/** A quiet card on the Agents page: how many changed files across the open chats still wait for a look. Absent when none do. */
@Composable
fun ToReviewCard(queue: ReviewQueue, onOpen: () -> Unit, modifier: Modifier = Modifier) {
    when {
        queue.pendingFileCount > 0 -> Column(modifier.fillMaxWidth().hubCardSurface(peeringShapes.large).tappable(onOpen)) {
            TitleBar(queue)
            HorizontalDivider(color = PeeringColors.hairline)
            val shown = queue.groups.flatMap { it.pending }.take(PREVIEW_COUNT)
            shown.forEach { PreviewRow(it) }
            val more = queue.pendingFileCount - shown.size
            if (more > 0) {
                Text(
                    pluralStringResource(R.plurals.review_more_files, more, more),
                    style = PeeringText.caption,
                    color = PeeringColors.muted,
                    modifier = Modifier.padding(horizontal = 14.dp).padding(bottom = 10.dp),
                )
            }
        }
        queue.checking -> Box(Modifier.fillMaxWidth().height(CHECKING_HEIGHT))
    }
}

private val CHECKING_HEIGHT = 46.dp

@Composable
private fun TitleBar(queue: ReviewQueue) {
    Row(
        Modifier.fillMaxWidth().height(CHECKING_HEIGHT).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            repeat(3) { Box(Modifier.size(8.dp).background(PeeringColors.ink.copy(alpha = 0.16f), CircleShape)) }
        }
        Column(Modifier.weight(1f)) {
            Text(stringResource(R.string.review_title), style = PeeringText.subheadlineSemibold, color = PeeringColors.ink)
            Text(
                pluralStringResource(R.plurals.review_files, queue.pendingFileCount, queue.pendingFileCount) + " " +
                    pluralStringResource(R.plurals.review_in_chats, queue.pendingChatCount, queue.pendingChatCount),
                style = PeeringText.caption2,
                color = PeeringColors.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        DiffCounts(queue.added, queue.removed)
        Icon(AppIcons.chevronRight, contentDescription = null, tint = PeeringColors.tertiary, modifier = Modifier.size(14.dp))
    }
}

@Composable
private fun PreviewRow(file: ReviewFile) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            file.path.substringAfterLast('/'),
            style = PeeringText.footnote,
            color = PeeringColors.ink,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        DiffCounts(file.file.added, file.file.removed, size = 10)
    }
}
