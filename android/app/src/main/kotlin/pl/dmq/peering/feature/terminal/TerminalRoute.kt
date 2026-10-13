package pl.dmq.peering.feature.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import kotlinx.coroutines.launch
import pl.dmq.peering.R
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.session.terminal.TerminalTab
import pl.dmq.peering.ui.theme.PeeringColors

/** What the screen keeps beyond the shells themselves: saved commands and the log's type size. */
class TerminalPreferences(val quickCommands: QuickCommands, val textSize: TerminalTextSizeSetting, val agentHistory: AgentLaunchHistory)

/**
 * The shells of one computer, laid out as the iPhone does: a strip of tabs, the output, the key deck and the command
 * line. [connected] is true while the session is live. With [canCreate] false the strip has no plus (the list page starts shells) and [onEnded] runs after one is ended. A [hosted] screen sits under a switcher that already names it and closes
 * it, so it draws no bar of its own: a tab carries each shell's name, rename and end.
 */
@Composable
fun TerminalRoute(
    sessions: TerminalSessions,
    preferences: TerminalPreferences,
    connected: Boolean,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    hosted: Boolean = false,
    canCreate: Boolean = true,
    onEnded: (() -> Unit)? = null,
) {
    val state by sessions.state.collectAsState()
    val selected = state.selected
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    val clipboard = LocalClipboardManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    val focus = remember { FocusRequester() }
    val commands by preferences.quickCommands.all.collectAsState()
    var textSize by remember { mutableStateOf(preferences.textSize.read()) }
    var command by remember { mutableStateOf("") }
    var history by remember { mutableStateOf(emptyList<String>()) }
    var showsHistory by remember { mutableStateOf(false) }
    var showsKeys by remember { mutableStateOf(false) }
    var editingCommands by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<TerminalTab?>(null) }
    var pendingEnd by remember { mutableStateOf<TerminalTab?>(null) }
    val copied = stringResource(R.string.terminal_copied)

    LaunchedEffect(state.failure) {
        state.failure?.let {
            snackbar.showSnackbar(it)
            sessions.dismissFailure()
        }
    }

    fun hasOutput(tab: TerminalTab) = sessions.frames(tab.id).value.hasPrinted()
    fun endNow(tab: TerminalTab) {
        sessions.close(tab.id)
        onEnded?.invoke()
    }
    fun requestEnd(tab: TerminalTab) {
        if (tab.isRunning || hasOutput(tab)) pendingEnd = tab else endNow(tab)
    }
    val tabActions = TerminalTabActions(
        onSelect = { sessions.select(it.id) },
        onClose = ::requestEnd,
        onRename = { renaming = it },
        onCopy = { tab ->
            clipboard.setText(AnnotatedString(screenText(sessions, tab)))
            scope.launch { snackbar.showSnackbar(copied) }
        },
    )
    fun send(tab: TerminalTab, text: String) = sessions.input(tab.id, text)

    Scaffold(
        modifier = modifier,
        containerColor = PeeringColors.backdrop,
        contentWindowInsets = WindowInsets.safeDrawing,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            Column {
                if (!hosted) TerminalTopBar(selected, onBack, onRename = { renaming = it }, onEnd = ::requestEnd)
                if (state.tabs.isNotEmpty()) {
                    TerminalTabStrip(
                        state.tabs,
                        state.selectedID,
                        { rememberHasPrinted(sessions, it.id).value },
                        tabActions,
                        onNew = if (canCreate) sessions::open else null,
                        newEnabled = connected,
                    )
                }
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            when {
                !state.loaded -> TerminalLoading(waitingForConnection = !connected)
                selected == null -> TerminalEmpty(onNew = sessions::open)
                else -> {
                    Box(Modifier.weight(1f)) {
                        key(selected.id) {
                            TerminalOutput(sessions, selected, textSize.points) {
                                focus.requestFocus()
                                keyboardController?.show()
                            }
                        }
                    }
                    if (showsHistory && history.isNotEmpty()) {
                        TerminalHistoryStrip(history, selected.isRunning, onPick = {
                            command = it
                            focus.requestFocus()
                        })
                    }
                    TerminalDeck(onMore = { showsKeys = true }, send = { send(selected, it) }, isEnabled = selected.isRunning)
                    TerminalCommandBar(
                        CommandBarState(
                            text = command,
                            onText = { command = it },
                            isRunning = selected.isRunning,
                            historyVisible = showsHistory,
                            hasHistory = history.isNotEmpty(),
                            onToggleHistory = { showsHistory = !showsHistory },
                            onSubmit = {
                                send(selected, command + "\r")
                                history = history.withCommand(command)
                                command = ""
                            },
                            onEnter = { send(selected, "\r") },
                        ),
                        focus,
                    )
                }
            }
        }
    }

    if (showsKeys && selected != null) {
        TerminalAllKeys(
            AllKeysActions(
                commands = commands,
                textSize = textSize,
                send = { send(selected, it) },
                run = { send(selected, it.command + "\r") },
                remove = preferences.quickCommands::delete,
                edit = { editingCommands = true },
                onTextSize = {
                    textSize = it
                    preferences.textSize.write(it)
                },
            ),
            onDismiss = { showsKeys = false },
        )
    }
    if (editingCommands) {
        QuickCommandEditor(commands, preferences.quickCommands::save, preferences.quickCommands::delete) { editingCommands = false }
    }
    renaming?.let { tab ->
        RenameTerminalDialog(tab, onCancel = { renaming = null }, onSave = {
            sessions.rename(tab.id, it)
            renaming = null
        })
    }
    pendingEnd?.let { tab ->
        EndTerminalPrompt(tab, onKeep = { pendingEnd = null }, onEnd = {
            endNow(tab)
            pendingEnd = null
        })
    }
}

@Composable
private fun TerminalOutput(sessions: TerminalSessions, tab: TerminalTab, fontSize: Int, onTap: () -> Unit) {
    val printed by rememberHasPrinted(sessions, tab.id)
    Box(Modifier.fillMaxSize()) {
        TerminalCanvas(
            frames = sessions.frames(tab.id),
            onGrid = { columns, rows -> sessions.resize(tab.id, columns, rows) },
            onTap = onTap,
            fontSize = fontSize,
            modifier = Modifier.fillMaxSize(),
        )
        if (!printed) {
            Box(Modifier.fillMaxSize().background(PeeringColors.backdrop)) {
                if (tab.isRunning) TerminalStarting() else TerminalNothingPrinted()
            }
        }
    }
}

private fun screenText(sessions: TerminalSessions, tab: TerminalTab): String {
    val snapshot = sessions.snapshot(tab.id)
    return snapshot.lines.takeLast(snapshot.rows).joinToString("\n") { it.text.trimEnd() }.trimEnd()
}
