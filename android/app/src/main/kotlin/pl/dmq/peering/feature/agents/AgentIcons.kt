package pl.dmq.peering.feature.agents

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.automirrored.outlined.Undo
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Difference
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.NorthWest
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material.icons.outlined.QuestionAnswer
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.Replay
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material.icons.outlined.SubdirectoryArrowRight
import androidx.compose.material.icons.outlined.UnfoldMore
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.North
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Search
import androidx.compose.ui.graphics.vector.ImageVector

/** The Material glyphs the agent screens use for the iPhone's SF Symbols, named for what they mean there. */
internal object AgentIcons {
    val chats: ImageVector get() = Icons.AutoMirrored.Outlined.Chat
    val hand: ImageVector get() = Icons.Outlined.PanTool
    val history: ImageVector get() = Icons.Outlined.History
    val changes: ImageVector get() = Icons.Outlined.Difference
    val review: ImageVector get() = Icons.Outlined.Checklist
    val send: ImageVector get() = Icons.Outlined.ArrowUpward
    val stop: ImageVector get() = Icons.Outlined.Stop
    val model: ImageVector get() = Icons.Outlined.Memory
    val clock: ImageVector get() = Icons.Outlined.Schedule
    val restart: ImageVector get() = Icons.AutoMirrored.Outlined.Undo
    val replay: ImageVector get() = Icons.Outlined.Replay
    val usage: ImageVector get() = Icons.Outlined.Speed
    val plus: ImageVector get() = Icons.Outlined.Add
    val archive: ImageVector get() = Icons.Outlined.Inventory2
    val upLeft: ImageVector get() = Icons.Outlined.NorthWest
    val turnRight: ImageVector get() = Icons.Outlined.SubdirectoryArrowRight
    val info: ImageVector get() = Icons.Outlined.Info
    val denied: ImageVector get() = Icons.Outlined.Block
    val question: ImageVector get() = Icons.Outlined.QuestionAnswer
    val unselected: ImageVector get() = Icons.Outlined.RadioButtonUnchecked
    val selected: ImageVector get() = Icons.Filled.CheckCircle
    val more: ImageVector get() = Icons.Outlined.MoreHoriz
    val chooser: ImageVector get() = Icons.Outlined.UnfoldMore
    val acceptEdits: ImageVector get() = Icons.Outlined.VerifiedUser
    val auto: ImageVector get() = Icons.Outlined.Bolt
    val sendPlane: ImageVector get() = Icons.AutoMirrored.Outlined.Send
    val search: ImageVector get() = Icons.Outlined.Search
    val up: ImageVector get() = Icons.Outlined.North
}
