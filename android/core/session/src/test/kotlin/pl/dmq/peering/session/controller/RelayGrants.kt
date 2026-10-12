package pl.dmq.peering.session.controller

import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import pl.dmq.peering.session.testing.FakeSignalling
import pl.dmq.peering.wire.RelayServerMessage
import pl.dmq.peering.wire.Token

/** The relay's answer to a connect: a control socket and a video lane at fixed addresses. */
internal fun FakeSignalling.grantSession() {
    reply(
        RelayServerMessage.SessionReady(
            controlHost = "control.example",
            controlPort = 4431,
            videoHost = "video.example",
            videoPort = 4500,
            controlToken = Token(ByteArray(Token.SIZE) { 1 }),
            videoToken = Token(ByteArray(Token.SIZE) { 2 }),
        ),
    )
}

internal suspend fun TestScope.settle() {
    advanceTimeBy(100)
    runCurrent()
}
