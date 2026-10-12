package pl.dmq.peering.ui.kit

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MediumTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * A top level screen under Material's medium top app bar: the title in the display face collapses to a small bar as
 * [content] scrolls. A [detail] line sits under the bar. With [scrollable] false the content manages its own scrolling.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TitleBarScreen(
    title: String,
    modifier: Modifier = Modifier,
    detail: String? = null,
    scrollable: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets(0),
        topBar = {
            MediumTopAppBar(
                title = { Text(title) },
                colors = TopAppBarDefaults.mediumTopAppBarColors(
                    containerColor = Color.Transparent,
                    scrolledContainerColor = PeeringColors.container,
                    titleContentColor = PeeringColors.ink,
                ),
                scrollBehavior = scrollBehavior,
            )
        },
    ) { padding ->
        val body = Modifier.fillMaxSize().padding(padding).let { if (scrollable) it.verticalScroll(rememberScrollState()) else it }
        Column(body.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (detail != null) Text(detail, style = MaterialTheme.typography.bodyMedium, color = PeeringColors.muted)
            content()
        }
    }
}
