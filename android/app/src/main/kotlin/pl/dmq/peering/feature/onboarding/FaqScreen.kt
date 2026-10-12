package pl.dmq.peering.feature.onboarding

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.OutlinedPanel
import pl.dmq.peering.ui.theme.PeeringColors

/** The questions and answers from [FaqEntries]. Each answer opens in place. */
@Composable
fun FaqScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Text(
                stringResource(R.string.faq_back),
                style = MaterialTheme.typography.labelLarge,
                color = PeeringColors.muted,
                modifier = Modifier.clickable(onClick = onBack).padding(bottom = 4.dp),
            )
        }
        items(FaqEntries.sections, key = { it.titleRes }) { section ->
            Text(
                stringResource(section.titleRes),
                style = MaterialTheme.typography.titleSmall,
                color = PeeringColors.muted,
                modifier = Modifier.padding(top = 8.dp),
            )
            section.items.forEach { item -> FaqRow(item) }
        }
    }
}

@Composable
private fun FaqRow(item: FaqItem) {
    var open by rememberSaveable(item.questionRes) { mutableStateOf(false) }
    OutlinedPanel(modifier = Modifier.fillMaxWidth().clickable { open = !open }) {
        Text(stringResource(item.questionRes), style = MaterialTheme.typography.titleSmall, color = PeeringColors.ink)
        if (open) {
            Text(
                stringResource(item.answerRes),
                style = MaterialTheme.typography.bodyMedium,
                color = PeeringColors.muted,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}
