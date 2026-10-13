package pl.dmq.peering.feature.remote

import pl.dmq.peering.wire.MouseDown
import pl.dmq.peering.wire.MouseMove
import pl.dmq.peering.wire.MouseUp
import pl.dmq.peering.wire.NormalizedPoint
import pl.dmq.peering.wire.PointerAction
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.Scroll

fun PointerAction.toCommands(): List<RemoteCommand> = when (this) {
    is PointerAction.MoveTo -> listOf(MouseMove(NormalizedPoint(nx, ny)))
    is PointerAction.ButtonDown -> listOf(MouseDown(button))
    is PointerAction.ButtonUp -> listOf(MouseUp(button))
    is PointerAction.Click -> listOf(MouseDown(button), MouseUp(button))
    is PointerAction.Scroll -> listOf(Scroll(dx, dy))
}
