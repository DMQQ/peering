package pl.dmq.peering.feature.pairing

import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HostIdEntryPresenterTest {
    private val validId = "3d9f1c7a-2b44-4e71-9c0a-5f2e8b1d6a33"
    private val canonicalId = "3D9F1C7A-2B44-4E71-9C0A-5F2E8B1D6A33"

    @Test
    fun aValidIdIsAcceptedUppercasedAndReported() = runTest(UnconfinedTestDispatcher()) {
        val accepted = mutableListOf<String>()
        val presenter = HostIdEntryPresenter(FakeQrSource(), backgroundScope) { accepted += it }

        presenter.onTextChanged(validId)
        presenter.submit()

        assertEquals(listOf(canonicalId), accepted)
        assertNull(presenter.state.value.error)
    }

    @Test
    fun aDeviceLinkIsAcceptedAsItsId() = runTest(UnconfinedTestDispatcher()) {
        val accepted = mutableListOf<String>()
        val presenter = HostIdEntryPresenter(FakeQrSource(), backgroundScope) { accepted += it }

        presenter.onTextChanged("https://getpeering.app/mac?id=$validId")
        presenter.submit()

        assertEquals(listOf(canonicalId), accepted)
    }

    @Test
    fun anEmptySubmitShowsTheEmptyError() = runTest(UnconfinedTestDispatcher()) {
        val accepted = mutableListOf<String>()
        val presenter = HostIdEntryPresenter(FakeQrSource(), backgroundScope) { accepted += it }

        presenter.onTextChanged("   ")
        presenter.submit()

        assertEquals(HostIdError.Empty, presenter.state.value.error)
        assertEquals(emptyList<String>(), accepted)
    }

    @Test
    fun theSixDigitCodeIsRefusedInPlaceOfAnId() = runTest(UnconfinedTestDispatcher()) {
        val accepted = mutableListOf<String>()
        val presenter = HostIdEntryPresenter(FakeQrSource(), backgroundScope) { accepted += it }

        presenter.onTextChanged("042317")
        presenter.submit()

        assertEquals(HostIdError.CodeInsteadOfId, presenter.state.value.error)
        assertEquals(emptyList<String>(), accepted)
    }

    @Test
    fun aPairingCodeLinkIsRefusedAsCodeInsteadOfId() = runTest(UnconfinedTestDispatcher()) {
        val presenter = HostIdEntryPresenter(FakeQrSource(), backgroundScope) {}

        presenter.onTextChanged("peering://pair?code=042317")
        presenter.submit()

        assertEquals(HostIdError.CodeInsteadOfId, presenter.state.value.error)
    }

    @Test
    fun aForeignQrCodeIsNotAPeeringCode() = runTest(UnconfinedTestDispatcher()) {
        val presenter = HostIdEntryPresenter(FakeQrSource(), backgroundScope) {}

        presenter.onTextChanged("WIFI:S:home;T:WPA;P:secret;;")
        presenter.submit()

        assertEquals(HostIdError.NotPairingCode, presenter.state.value.error)
    }

    @Test
    fun aMistypedIdIsNotAnIdentifier() = runTest(UnconfinedTestDispatcher()) {
        val presenter = HostIdEntryPresenter(FakeQrSource(), backgroundScope) {}

        presenter.onTextChanged("my mac")
        presenter.submit()

        assertEquals(HostIdError.NotAnIdentifier, presenter.state.value.error)
    }

    @Test
    fun editingTheTextClearsTheError() = runTest(UnconfinedTestDispatcher()) {
        val presenter = HostIdEntryPresenter(FakeQrSource(), backgroundScope) {}
        presenter.onTextChanged("my mac")
        presenter.submit()

        presenter.onTextChanged("my mac again")

        assertNull(presenter.state.value.error)
    }

    @Test
    fun scannedTextGoesThroughTheSameValidation() = runTest(UnconfinedTestDispatcher()) {
        val accepted = mutableListOf<String>()
        val scanned = flowOf("https://getpeering.app/mac?id=$validId")
        HostIdEntryPresenter(FakeQrSource(scanned), backgroundScope) { accepted += it }

        assertEquals(listOf(canonicalId), accepted)
    }

    @Test
    fun aScannedCodeThatIsNotAnIdIsShownInTheField() = runTest(UnconfinedTestDispatcher()) {
        val scanned = flowOf("WIFI:S:home;;")
        val presenter = HostIdEntryPresenter(FakeQrSource(scanned), backgroundScope) {}

        assertEquals("WIFI:S:home;;", presenter.state.value.text)
        assertEquals(HostIdError.NotPairingCode, presenter.state.value.error)
    }
}

class HostIdEntryUntouchedTest {
    @Test
    fun anUntouchedFieldHasNoErrorAndCannotBeSubmitted() = runTest(UnconfinedTestDispatcher()) {
        val presenter = HostIdEntryPresenter(FakeQrSource(), backgroundScope) {}

        assertNull(presenter.state.value.error)
        assertEquals(false, presenter.state.value.canSubmit)
    }

    @Test
    fun typingAnInvalidValueShowsNoErrorUntilItIsSubmitted() = runTest(UnconfinedTestDispatcher()) {
        val presenter = HostIdEntryPresenter(FakeQrSource(), backgroundScope) {}

        presenter.onTextChanged("zzz")
        assertNull(presenter.state.value.error)

        presenter.submit()
        assertEquals(HostIdError.NotAnIdentifier, presenter.state.value.error)

        presenter.onTextChanged("zzzz")
        assertNull(presenter.state.value.error)
    }
}
