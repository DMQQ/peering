package pl.dmq.peering.feature.connect

import org.junit.Test
import org.junit.Assert.assertEquals
import pl.dmq.peering.feature.pairing.PairingCodeScreen
import pl.dmq.peering.ui.kit.GuideStepState

class FirstConnectionStepsTest {
    @Test
    fun beforeAChoiceOnlyTheChooseStepCanBeCurrent() {
        assertEquals(FirstConnectionSteps(GuideStepState.Pending, GuideStepState.Pending, GuideStepState.Pending), firstConnectionSteps(null, listReady = false))
        assertEquals(FirstConnectionSteps(GuideStepState.Current, GuideStepState.Pending, GuideStepState.Pending), firstConnectionSteps(null, listReady = true))
    }

    @Test
    fun connectingKeepsTheChooseStepCurrent() {
        assertEquals(GuideStepState.Current, firstConnectionSteps(PairingCodeScreen.Connecting, listReady = true).choose)
    }

    @Test
    fun enteringTheCodeMakesTheCodeStepCurrent() {
        val steps = firstConnectionSteps(PairingCodeScreen.EnteringCode(attempts = 0, error = null), listReady = true)
        assertEquals(FirstConnectionSteps(GuideStepState.Done, GuideStepState.Current, GuideStepState.Pending), steps)
    }

    @Test
    fun waitingForTheComputerMakesApproveCurrent() {
        assertEquals(FirstConnectionSteps(GuideStepState.Done, GuideStepState.Done, GuideStepState.Current), firstConnectionSteps(PairingCodeScreen.Waiting, listReady = true))
    }

    @Test
    fun aFinishedPairingTicksEverything() {
        assertEquals(FirstConnectionSteps(GuideStepState.Done, GuideStepState.Done, GuideStepState.Done), firstConnectionSteps(PairingCodeScreen.Done, listReady = true))
    }
}
