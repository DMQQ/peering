package pl.dmq.peering.feature.connect

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import pl.dmq.peering.feature.pairing.FakeQrSource

class ConnectEntryActionsTest {
    @Test
    fun anUntouchedEntryShowsNoErrorAndCannotSubmit() = runTest(UnconfinedTestDispatcher()) {
        val presenter = presenter(mutableListOf(), backgroundScope)
        assertNull(presenter.state.value.entry.error)
        assertFalse(presenter.state.value.entry.canSubmit)
    }

    @Test
    fun submittingGarbageShowsAnErrorOnlyAfterTheSubmitAndTypingClearsIt() = runTest(UnconfinedTestDispatcher()) {
        val paired = mutableListOf<String>()
        val presenter = presenter(paired, backgroundScope)

        presenter.entry.onTextChanged("not an id !!")
        assertNull(presenter.state.value.entry.error)
        presenter.entry.submit()
        assertNotNull(presenter.state.value.entry.error)
        assertEquals(emptyList<String>(), paired)

        presenter.entry.onTextChanged("n")
        assertNull(presenter.state.value.entry.error)
    }

    @Test
    fun anAddressThatIsNotOneIsIgnoredAndAGoodOneIsDialled() = runTest(UnconfinedTestDispatcher()) {
        val dialled = mutableListOf<ManualAddress>()
        val presenter = ConnectPresenter(
            hosts = FakeHostSource(),
            presence = FakePresenceSource(),
            qrSource = FakeQrSource(),
            onConnect = { _ -> },
            onPair = { _ -> },
            onConnectAddress = { dialled += it },
            scope = backgroundScope,
        )

        presenter.connectToAddress("two words", "7000")
        presenter.connectToAddress("192.168.1.20", "7000")

        assertEquals(listOf(ManualAddress("192.168.1.20", 7000)), dialled)
    }

    private fun presenter(paired: MutableList<String>, scope: CoroutineScope) = ConnectPresenter(
        hosts = FakeHostSource(),
        presence = FakePresenceSource(),
        qrSource = FakeQrSource(),
        onConnect = { _ -> },
        onPair = { paired += it },
        onConnectAddress = { _ -> },
        scope = scope,
    )
}
