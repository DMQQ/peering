package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.scan.ScanOutcome
import pl.dmq.peering.session.connection.FailureReason
import pl.dmq.peering.session.controller.CodeCheck
import pl.dmq.peering.session.controller.ConnectFailureKind
import pl.dmq.peering.session.controller.PairingCodeError
import pl.dmq.peering.wire.PairingPayload

class PairingCodePresenterTest {
    @Test
    fun theRightCodeMovesToWaitingThenDone() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)
        assertEquals(PairingCodeScreen.EnteringCode(0, null), presenter.state.value)

        assertEquals(CodeCheck.Match, presenter.submitCode("042317"))
        assertEquals(PairingCodeScreen.Waiting, presenter.state.value)

        session.emit(PairingPhase.Done)
        assertEquals(PairingCodeScreen.Done, presenter.state.value)
    }

    @Test
    fun aWrongCodeShowsTheErrorAndAllowsAnotherTry() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)

        assertEquals(CodeCheck.Mismatch, presenter.submitCode("111111"))
        assertEquals(PairingCodeScreen.EnteringCode(1, PairingCodeError.WrongCode), presenter.state.value)

        assertEquals(CodeCheck.Match, presenter.submitCode("042317"))
        assertEquals(PairingCodeScreen.Waiting, presenter.state.value)
    }

    @Test
    fun tooManyWrongCodesFailTheScreenAndStopSendingDigits() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession(limit = 2)
        val presenter = PairingCodePresenter(session, backgroundScope)

        presenter.submitCode("111111")
        assertEquals(CodeCheck.TooManyAttempts, presenter.submitCode("222222"))
        session.emit(PairingPhase.Failed(FailureReason.PairingDeclined))
        presenter.submitCode("042317")

        assertEquals(PairingCodeScreen.Failed(PairingMessage.TooManyAttempts), presenter.state.value)
        assertEquals(listOf("111111", "222222"), session.typed)
    }

    @Test
    fun aSecondRightCodeIsNotSentAgain() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)

        presenter.submitCode("042317")
        presenter.submitCode("042317")

        assertEquals(listOf("042317"), session.typed)
    }

    @Test
    fun cancelStopsTheSessionAndShowsCancelledEvenIfItFailsAfterwards() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
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
    fun digitsAfterCancelAreNotSent() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)

        presenter.cancel()
        presenter.submitCode("042317")

        assertTrue(session.typed.isEmpty())
    }

    @Test
    fun aScannedCodeWithASecretConfirmsWithoutTyping() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)
        val secret = ByteArray(16) { 3 }

        val outcome = presenter.confirmScannedCode(PairingPayload.codeLink("042317", secret))

        assertEquals(ScanOutcome.Used, outcome)
        assertTrue(session.typed.isEmpty())
        assertEquals(PairingCodeScreen.Waiting, presenter.state.value)
        assertTrue(secret.contentEquals(session.secrets.single()))
    }

    @Test
    fun aScannedCodeThatIsNotTheComputersIsWrongAndAScanOfSomethingElseIsNotACode() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)

        assertEquals(ScanOutcome.WrongCode, presenter.confirmScannedCode(PairingPayload.codeLink("999999")))
        assertEquals(ScanOutcome.NotAPairingCode, presenter.confirmScannedCode("https://example.com"))
    }

    @Test
    fun aFailureFromTheSessionKeepsItsTextReason() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)

        session.emit(PairingPhase.Failed(FailureReason.PairingRefused("The computer is busy")))

        assertEquals(
            PairingCodeScreen.Failed(PairingMessage.Refused("The computer is busy")),
            presenter.state.value,
        )
    }

    @Test
    fun theCodeNeverAppearsInAnythingTheScreenExposes() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)
        val seen = mutableListOf(presenter.state.value.toString(), session.phases.value.toString())

        presenter.submitCode("111111")
        seen += presenter.state.value.toString()
        seen += session.phases.value.toString()
        presenter.submitCode("042317")
        seen += presenter.state.value.toString()

        assertFalse(seen.any { "042317" in it })
    }

    @Test
    fun aConnectionFailureShowsItsMessageAndDetails() = runTest(UnconfinedTestDispatcher()) {
        val session = FakePairingSession()
        val presenter = PairingCodePresenter(session, backgroundScope)

        session.emit(PairingPhase.ConnectionFailed(ConnectFailureKind.Refused, "ConnectException: refused"))

        assertEquals(
            PairingCodeScreen.Failed(PairingMessage.ConnectionRefused, "ConnectException: refused"),
            presenter.state.value,
        )
    }
}
