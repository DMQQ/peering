package pl.dmq.peering.ui.kit

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText

data class TabBarItem(val key: String, val label: String, val icon: ImageVector)

/** What the bar takes from the bottom of the screen above the navigation inset: content that must clear it adds this. */
val FloatingTabBarClearance: Dp = 60.dp + 16.dp

/** The iOS 26 tab bar replicated: a glass capsule floating above the bottom edge, the selected tab in a lighter pill and the accent. */
@Composable
fun FloatingTabBar(items: List<TabBarItem>, selectedKey: String, onSelect: (String) -> Unit, modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).padding(horizontal = 21.dp, vertical = 8.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(60.dp)
                .shadow(14.dp, CircleShape, ambientColor = Color.Black, spotColor = Color.Black)
                .glassSurface(CircleShape)
                .padding(4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            items.forEach { item ->
                TabBarButton(item, selected = item.key == selectedKey, onClick = { onSelect(item.key) }, modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun TabBarButton(item: TabBarItem, selected: Boolean, onClick: () -> Unit, modifier: Modifier) {
    val tint by animateColorAsState(if (selected) PeeringColors.accent else Color.White.copy(alpha = 0.72f), label = "tabTint")
    val fill by animateColorAsState(if (selected) Color.White.copy(alpha = 0.10f) else Color.Transparent, label = "tabFill")
    Column(
        modifier = modifier
            .fillMaxHeight()
            .pressable(onClick, scale = 0.96f, role = Role.Tab)
            .background(fill, CircleShape),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(item.icon, contentDescription = null, tint = tint, modifier = Modifier.size(26.dp))
        Text(item.label, style = PeeringText.caption2.copy(fontWeight = FontWeight.Medium), color = tint, maxLines = 1)
    }
}
