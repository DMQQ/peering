package pl.dmq.peering.feature.agents.changes

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import pl.dmq.peering.R
import pl.dmq.peering.feature.agents.AgentIcons
import pl.dmq.peering.session.agent.changes.ReviewComment
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.peeringShapes

@Composable
fun CommentCard(comment: ReviewComment, onRemove: (Long) -> Unit, modifier: Modifier = Modifier) {
    val shape = peeringShapes.extraSmall
    Row(
        modifier.fillMaxWidth().border(1.dp, PeeringColors.hairline, shape).padding(start = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(AgentIcons.chats, contentDescription = null, tint = PeeringColors.muted, modifier = Modifier.size(14.dp))
        Text(comment.text, style = PeeringText.footnote, color = PeeringColors.ink.copy(alpha = 0.9f), modifier = Modifier.weight(1f).padding(vertical = 10.dp))
        IconButton(onClick = { onRemove(comment.id) }, modifier = Modifier.size(40.dp)) {
            Icon(AppIcons.close, contentDescription = stringResource(R.string.changes_comment_remove), tint = PeeringColors.muted, modifier = Modifier.size(16.dp))
        }
    }
}

/** A field over the keyboard that names what the comment is about, with Add and Cancel. */
@Composable
fun CommentComposer(label: String, onAdd: (String) -> Unit, onCancel: () -> Unit, modifier: Modifier = Modifier) {
    var text by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Column(modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, style = PeeringText.caption2Monospaced, color = PeeringColors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 14.dp))
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                Modifier.weight(1f).border(1.dp, PeeringColors.hairline, peeringShapes.small).padding(start = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.weight(1f).padding(vertical = 12.dp)) {
                    if (text.isEmpty()) Text(stringResource(R.string.changes_comment_hint), style = PeeringText.body.copy(fontSize = 16.sp), color = PeeringColors.ink.copy(alpha = 0.4f))
                    BasicTextField(
                        value = text,
                        onValueChange = { text = it },
                        textStyle = PeeringText.body.copy(fontSize = 16.sp, color = PeeringColors.ink),
                        cursorBrush = SolidColor(PeeringColors.ink),
                        maxLines = 6,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 24.dp).focusRequester(focus),
                    )
                }
                IconButton(onClick = onCancel) {
                    Icon(AppIcons.close, contentDescription = stringResource(R.string.changes_comment_cancel), tint = PeeringColors.muted, modifier = Modifier.size(18.dp))
                }
            }
            val enabled = text.isNotBlank()
            Text(
                stringResource(R.string.changes_comment_add),
                style = PeeringText.subheadlineSemibold,
                color = if (enabled) PeeringColors.accent else PeeringColors.tertiary,
                modifier = Modifier
                    .clickable(enabled = enabled, role = Role.Button) { onAdd(text) }
                    .padding(horizontal = 12.dp, vertical = 14.dp),
            )
        }
    }
}
