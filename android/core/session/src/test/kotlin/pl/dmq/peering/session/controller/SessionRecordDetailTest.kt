@file:OptIn(ExperimentalCoroutinesApi::class)

package pl.dmq.peering.session.controller

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.flows.ScriptedPairingHost

class SessionRecordDetailTest {
    @Test
    fun anEndedSessionRecordCarriesTheBytesItMovedAndItsLog() = runTest {
        val rig = ControllerRig(this, testScheduler, ConnectTarget.Lan(ControllerRig.LAN_ADDRESS, ScriptedPairingHost.HOST_ID))
        rig.controller.connect()
        advanceTimeBy(1_000)
        runCurrent()

        rig.controller.disconnect()
        runCurrent()

        val record = rig.history.records.single()
        assertTrue(record.bytesReceived > 0)
        assertTrue(record.bytesSent > 0)
        assertTrue(record.logs.any { it.contains("control connection open over LAN") })
        assertTrue(record.logs.last().endsWith("session ended: USER_ENDED"))
    }
}
