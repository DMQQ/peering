package pl.dmq.peering.feature.agents.preview

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.theme.PeeringColors
import pl.dmq.peering.ui.theme.PeeringText
import pl.dmq.peering.ui.theme.PillShape

/** A web page served by the computer's own loopback, shown on the phone through the connection the session already has. */
@Composable
fun PreviewScreen(fetch: PreviewFetch, onClose: () -> Unit, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val presenter = remember(fetch) { PreviewPresenter(fetch, scope) }
    val context = LocalContext.current
    val web = remember(presenter) { PreviewWeb(context, presenter, fetch) }
    DisposableEffect(web) { onDispose(web::close) }
    LaunchedEffect(presenter) { presenter.detect() }
    val ui by presenter.ui.collectAsState()
    var typed by remember { mutableStateOf("") }
    var typedEdited by remember { mutableStateOf(false) }
    LaunchedEffect(ui.address) { if (!typedEdited) typed = ui.address }
    val open = {
        typedEdited = false
        presenter.open(typed)?.let { web.load(it.url) }
        Unit
    }
    BackHandler(onBack = { if (ui.canGoBack) web.goBack() else onClose() })

    Surface(modifier.fillMaxSize(), color = PeeringColors.backdrop) {
        Column(Modifier.fillMaxSize().navigationBarsPadding()) {
            TopBar(onClose)
            AddressBar(
                typed = typed,
                onTyped = {
                    typed = it
                    typedEdited = true
                },
                canGoBack = ui.canGoBack,
                canReload = ui.phase != PreviewPhase.IDLE,
                onGo = open,
                onBack = web::goBack,
                onReload = web::reload,
            )
            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (ui.phase == PreviewPhase.IDLE) {
                    PreviewStart(ui, onOpenPort = { typed = "localhost:$it"; open() }, onLookAgain = presenter::detect)
                } else if (ui.phase == PreviewPhase.FAILED) {
                    PreviewFailureView(ui.failure, onRetry = web::reload)
                }
                PageLayer(web, visible = ui.phase == PreviewPhase.LOADING || ui.phase == PreviewPhase.LOADED, loading = ui.phase == PreviewPhase.LOADING)
            }
            ui.notice?.let { notice ->
                Text(
                    stringResource(if (notice == PreviewNotice.ONLY_LOOPBACK) R.string.preview_notice_only_loopback else R.string.preview_notice_links_outside),
                    style = PeeringText.caption,
                    color = PeeringColors.caution,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun TopBar(onClose: () -> Unit) {
    Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onClose) {
            Icon(AppIcons.close, contentDescription = stringResource(R.string.preview_done), tint = PeeringColors.ink)
        }
        Text(stringResource(R.string.preview_title), style = PeeringText.subheadlineSemibold.copy(fontSize = 17.sp), color = PeeringColors.ink)
    }
}

/** One capsule: back and reload sit inside it instead of beside it as three separate controls. */
@Composable
private fun AddressBar(
    typed: String,
    onTyped: (String) -> Unit,
    canGoBack: Boolean,
    canReload: Boolean,
    onGo: () -> Unit,
    onBack: () -> Unit,
    onReload: () -> Unit,
) {
    Row(
        Modifier.padding(horizontal = 14.dp, vertical = 8.dp).fillMaxWidth().height(44.dp).border(1.dp, PeeringColors.ink.copy(alpha = 0.16f), PillShape),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (canGoBack) {
            IconButton(onClick = onBack, modifier = Modifier.size(44.dp)) {
                Icon(AppIcons.back, contentDescription = stringResource(R.string.preview_back), tint = PeeringColors.ink, modifier = Modifier.size(20.dp))
            }
        }
        Box(Modifier.weight(1f).padding(start = if (canGoBack) 2.dp else 16.dp), contentAlignment = Alignment.CenterStart) {
            if (typed.isEmpty()) {
                Text(stringResource(R.string.preview_address_hint), style = PeeringText.subheadline.copy(fontFamily = FontFamily.Monospace), color = PeeringColors.tertiary)
            }
            BasicTextField(
                value = typed,
                onValueChange = onTyped,
                singleLine = true,
                textStyle = PeeringText.subheadline.copy(fontFamily = FontFamily.Monospace, color = PeeringColors.ink),
                cursorBrush = SolidColor(PeeringColors.accent),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { onGo() }),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        IconButton(onClick = onReload, enabled = canReload, modifier = Modifier.size(44.dp)) {
            Icon(
                AppIcons.refresh,
                contentDescription = stringResource(R.string.preview_reload),
                tint = if (canReload) PeeringColors.ink else PeeringColors.tertiary,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun PageLayer(web: PreviewWeb, visible: Boolean, loading: Boolean) {
    if (!visible) return
    Column(Modifier.fillMaxSize()) {
        if (loading) {
            LinearProgressIndicator(color = PeeringColors.ink.copy(alpha = 0.6f), trackColor = PeeringColors.hairline, modifier = Modifier.fillMaxWidth())
        } else {
            Box(Modifier.fillMaxWidth().height(4.dp))
        }
        AndroidView(factory = { web.view }, modifier = Modifier.weight(1f).fillMaxWidth())
    }
}
