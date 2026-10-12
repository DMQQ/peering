package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import kotlinx.coroutines.launch
import pl.dmq.peering.R
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.ui.kit.AppIcons
import pl.dmq.peering.ui.kit.PeeringMenu
import pl.dmq.peering.ui.kit.PeeringMenuItem
import pl.dmq.peering.ui.theme.PeeringColors

/**
 * The shells of one computer: Material tabs over a text canvas, with an extra keys row above the soft keyboard.
 * [connected] is true while the session is live; each time it becomes true the list is asked for again, which also
 * replays the output after a reconnect.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalRoute(sessions: TerminalSessions, connected: Boolean, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val state by sessions.state.collectAsState()
    val selected = state.selected
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    val clipboard = LocalClipboardManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    val focus = remember { FocusRequester() }
    val keyboard = remember(sessions, selected?.id) {
        TerminalKeyboard { bytes -> selected?.let { sessions.input(it.id, bytes) } }
    }
    var menuOpen by remember { mutableStateOf(false) }
    val copiedMessage = stringResource(R.string.terminal_copied)

    LaunchedEffect(sessions, connected) {
        if (connected) sessions.attach()
    }

    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
        contentWindowInsets = WindowInsets.safeDrawing,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            Column {
                TopAppBar(
                    title = { Text(stringResource(R.string.terminal_title)) },
                    navigationIcon = {
                        IconButton(onClick = onBack) { Icon(AppIcons.back, stringResource(R.string.terminal_back)) }
                    },
                    actions = {
                        IconButton(onClick = sessions::open, enabled = connected) {
                            Icon(TerminalGlyphs.add, stringResource(R.string.terminal_new))
                        }
                        IconButton(onClick = { menuOpen = true }, enabled = selected != null) {
                            Icon(AppIcons.more, stringResource(R.string.terminal_more))
                        }
                        Box {
                            PeeringMenu(expanded = menuOpen, onDismiss = { menuOpen = false }) {
                                PeeringMenuItem(stringResource(R.string.terminal_copy), icon = AppIcons.copy, onClick = {
                                    menuOpen = false
                                    selected?.let { clipboard.setText(AnnotatedString(screenText(sessions, it))) }
                                    scope.launch { snackbar.showSnackbar(copiedMessage) }
                                })
                                PeeringMenuItem(stringResource(R.string.terminal_paste), icon = TerminalGlyphs.paste, onClick = {
                                    menuOpen = false
                                    clipboard.getText()?.text?.let(keyboard::paste)
                                })
                                PeeringMenuItem(stringResource(R.string.terminal_close_tab), icon = AppIcons.close, destructive = true, onClick = {
                                    menuOpen = false
                                    selected?.let { sessions.close(it.id) }
                                })
                            }
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent, titleContentColor = PeeringColors.ink),
                )
                if (state.tabs.isNotEmpty()) TerminalTabs(state.tabs, state.selectedID, sessions::select)
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            when {
                !state.loaded -> TerminalLoading(waitingForConnection = !connected)
                selected == null -> TerminalEmpty(state.failure, onNew = sessions::open)
                else -> {
                    TerminalNotice(selected, state.failure, onNew = sessions::open, onDismissFailure = sessions::dismissFailure)
                    Box(Modifier.weight(1f)) {
                        key(selected.id) {
                            TerminalScreenView(sessions, selected) {
                                focus.requestFocus()
                                keyboardController?.show()
                            }
                        }
                        TerminalInput(keyboard, focus)
                    }
                    ExtraKeysRow(keyboard)
                }
            }
        }
    }
}

@Composable
private fun TerminalScreenView(sessions: TerminalSessions, tab: TerminalTab, onTap: () -> Unit) {
    val snapshot = remember(tab.id, tab.revision) { sessions.snapshot(tab.id) }
    TerminalCanvas(
        snapshot = snapshot,
        onGrid = { columns, rows -> sessions.resize(tab.id, columns, rows) },
        onTap = onTap,
    )
}

private fun screenText(sessions: TerminalSessions, tab: TerminalTab): String {
    val snapshot = sessions.snapshot(tab.id)
    return snapshot.lines.takeLast(snapshot.rows).joinToString("\n") { it.text.trimEnd() }.trimEnd()
}
