package pl.dmq.peering.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp

/**
 * The only place a corner radius is chosen. Every Material component reads these through MaterialTheme.shapes:
 * extraSmall for small tiles and menu items, small for chips and fields, medium for rows, large for cards and
 * menus, extraLarge for sheets, dialogs and floating bars. Buttons, chips and indicators use [PillShape].
 */
val peeringShapes = Shapes(
    extraSmall = RoundedCornerShape(12.dp),
    small = RoundedCornerShape(16.dp),
    medium = RoundedCornerShape(20.dp),
    large = RoundedCornerShape(28.dp),
    extraLarge = RoundedCornerShape(36.dp),
)

/** Fully rounded ends whatever the height. */
val PillShape: Shape = RoundedCornerShape(percent = 50)

/** Corners of the terminal keys, the iPhone's 7 for a single key and 9 for the wider ellipsis and the joined arrows. */
val KeyShape = RoundedCornerShape(7.dp)
val KeyGroupShape = RoundedCornerShape(9.dp)
