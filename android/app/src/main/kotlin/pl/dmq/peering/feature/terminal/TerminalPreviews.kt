package pl.dmq.peering.feature.terminal

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.tooling.preview.Preview
import pl.dmq.peering.session.terminal.TerminalSessions
import pl.dmq.peering.ui.theme.PeeringTheme
import pl.dmq.peering.wire.TerminalEvent
import pl.dmq.peering.wire.TerminalRequest
import pl.dmq.peering.wire.TerminalSessionInfo
import pl.dmq.peering.wire.toBase64

private fun discard(request: TerminalRequest) = Unit

private fun discardBytes(bytes: ByteArray) = Unit

private fun leave() = Unit

private const val SAMPLE = "\u001B[32mdmq@computer\u001B[0m:\u001B[34m~/projects\u001B[0m$ ls\r\n" +
    "\u001B[34mandroid\u001B[0m  \u001B[34mapple\u001B[0m  README.md\r\n" +
    "\u001B[32mdmq@computer\u001B[0m:\u001B[34m~/projects\u001B[0m$ "

private fun sessionWith(vararg names: String, output: String = SAMPLE): TerminalSessions {
    val sessions = TerminalSessions(send = ::discard)
    sessions.onEvent(TerminalEvent.Snapshot(names.mapIndexed { index, name -> TerminalSessionInfo("t$index", name, true, 40, 12) }))
    sessions.onEvent(TerminalEvent.Output("t0", output.toByteArray().toBase64()))
    return sessions
}

@Preview(showBackground = true, backgroundColor = 0xFF0A0A0B, widthDp = 360, heightDp = 640)
@Composable
private fun TerminalRunningPreview() {
    PeeringTheme {
        TerminalRoute(remember { sessionWith("zsh", "build") }, connected = true, onBack = ::leave)
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF0A0A0B, widthDp = 360, heightDp = 640)
@Composable
private fun TerminalEmptyPreview() {
    PeeringTheme {
        TerminalRoute(
            remember { TerminalSessions(send = ::discard).also { it.onEvent(TerminalEvent.Snapshot(emptyList())) } },
            connected = true,
            onBack = ::leave,
        )
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF0A0A0B, widthDp = 360, heightDp = 640)
@Composable
private fun TerminalWaitingPreview() {
    PeeringTheme {
        TerminalRoute(remember { TerminalSessions(send = ::discard) }, connected = false, onBack = ::leave)
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF0A0A0B, widthDp = 360)
@Composable
private fun ExtraKeysPreview() {
    PeeringTheme {
        ExtraKeysRow(remember { TerminalKeyboard(::discardBytes).also { it.toggleCtrl() } })
    }
}
