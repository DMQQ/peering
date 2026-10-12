package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import pl.dmq.peering.session.connection.FailureReason

class PairingCodePresenterTest {
    @Test
    fun matchingDigitsConfirmThenWaitForTheMacThenFinish() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession(PairingPhase.Confirming("042317"))
        val presenter = PairingCodePresenter(session, backgroundScope)
        assertEquals(PairingCodeScreen.Comparing("042317"), presenter.state.value)

        presenter.confirm(codesMatch = true)

        assertEquals(listOf(true), session.answers)
        assertEquals(PairingCodeScreen.Waiting, presenter.state.value)

        session.emit(PairingPhase.Done)

        assertEquals(PairingCodeScreen.Done, presenter.state.value)
    }

    @Test
    fun rejectingTheDigitsSendsFalseAndShowsDeclined() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession(PairingPhase.Confirming("042317"))
        val presenter = PairingCodePresenter(session, backgroundScope)

        presenter.confirm(codesMatch = false)
        session.emit(PairingPhase.Failed(FailureReason.PairingDeclined))

        assertEquals(listOf(false), session.answers)
        assertEquals(PairingCodeScreen.Failed(PairingMessage.Declined), presenter.state.value)
    }

    @Test
    fun aSecondAnswerIsNotSentToTheSession() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession(PairingPhase.Confirming("042317"))
        val presenter = PairingCodePresenter(session, backgroundScope)

        presenter.confirm(codesMatch = true)
        presenter.confirm(codesMatch = false)

        assertEquals(listOf(true), session.answers)
    }

    @Test
    fun cancelStopsTheSessionAndShowsCancelledEvenIfItFailsAfterwards() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession(PairingPhase.Confirming("042317"))
        val presenter = PairingCodePresenter(session, backgroundScope)

        presenter.cancel()
        session.emit(PairingPhase.Failed(FailureReason.PairingDeclined))

        assertEquals(1, session.cancelCount)
        assertEquals(PairingCodeScreen.Cancelled, presenter.state.value)
    }

    @Test
    fun cancelTwiceCancelsOnce() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)

        presenter.cancel()
        presenter.cancel()

        assertEquals(1, session.cancelCount)
    }

    @Test
    fun answersAfterCancelAreNotSent() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession(PairingPhase.Confirming("042317"))
        val presenter = PairingCodePresenter(session, backgroundScope)

        presenter.cancel()
        presenter.confirm(codesMatch = true)

        assertEquals(emptyList<Boolean>(), session.answers)
    }

    @Test
    fun aFailureFromTheSessionKeepsItsTextReason() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)

        session.emit(PairingPhase.Failed(FailureReason.PairingRefused("The Mac is busy")))

        assertEquals(
            PairingCodeScreen.Failed(PairingMessage.Refused("The Mac is busy")),
            presenter.state.value,
        )
    }
}
