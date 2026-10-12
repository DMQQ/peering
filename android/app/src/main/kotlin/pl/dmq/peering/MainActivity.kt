package pl.dmq.peering

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import pl.dmq.peering.ui.nav.PeeringScaffold
import pl.dmq.peering.ui.theme.PeeringTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            PeeringTheme { PeeringScaffold() }
        }
    }
}
