package pl.dmq.peering.feature.connect

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import pl.dmq.peering.R
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.kit.HeadingBrush
import pl.dmq.peering.ui.theme.wordmarkStyle

@Composable
internal fun ConnectHeader(modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(top = 12.dp)) {
        Image(
            painter = painterResource(R.drawable.pears),
            contentDescription = null,
            alignment = Alignment.CenterStart,
            modifier = Modifier.size(72.dp),
        )
        Spacer(Modifier.height(16.dp))
        Text(
            text = stringResource(R.string.app_name),
            style = wordmarkStyle.copy(brush = HeadingBrush),
            modifier = Modifier,
        )
        Text(
            text = stringResource(R.string.connect_tagline),
            style = PeeringText.subheadline,
            color = PeeringColors.muted,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}
