package pl.dmq.peering.ssh

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.advanceUntilIdle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import pl.dmq.peering.session.testing.FakeSecretStore
import pl.dmq.peering.ssh.hostkey.HostKeyGate
import pl.dmq.peering.ssh.hostkey.HostKeyPrompt
import pl.dmq.peering.ssh.hostkey.HostKeyPrompter
import pl.dmq.peering.ssh.hostkey.KnownHostsStore
import pl.dmq.peering.ssh.hostkey.OfferedHostKey
import pl.dmq.peering.ssh.hostkey.SshFingerprint
import pl.dmq.peering.ssh.model.SshEndpoint
import pl.dmq.peering.ssh.transport.SshFailure

@OptIn(ExperimentalCoroutinesApi::class)
class HostKeyTest {
    private val endpoint = SshEndpoint("Box.Example.com", 22)
    private val key = byteArrayOf(1, 2, 3)
    private val secrets = FakeSecretStore()
    private val store = KnownHostsStore(secrets)

    private fun gate(answers: MutableList<HostKeyPrompt>, accept: Boolean) =
        HostKeyGate(store, { 1_000 }) { prompt ->
            answers += prompt
            accept
        }

    @Test
    fun fingerprintMatchesOpenSshsSpellingWithoutPadding() {
        assertEquals("SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0", SshFingerprint.of("abc".encodeToByteArray()))
    }

    @Test
    fun theEndpointKeyIsLowercasedAndAlwaysNamesThePort() {
        assertEquals("box.example.com:22", endpoint.key)
        assertEquals("box.example.com:2222", SshEndpoint("BOX.example.com", 2222).key)
        assertEquals("Box.Example.com", endpoint.display)
        assertEquals("h:2222", SshEndpoint("h", 2222).display)
    }

    @Test
    fun anUnknownKeyIsAskedAboutAndRememberedWhenTrusted() = runTest {
        val asked = mutableListOf<HostKeyPrompt>()
        gate(asked, accept = true).verify(OfferedHostKey(endpoint, "ssh-ed25519", key))
        assertEquals(1, asked.size)
        assertEquals("ssh-ed25519", asked.single().algorithm)
        assertEquals(SshFingerprint.of(key), asked.single().fingerprint)
        assertTrue(store.decision(endpoint, key) is KnownHostsStore.Decision.Match)
    }

    @Test
    fun aKeyTheUserRefusesIsNotRemembered() = runTest {
        val asked = mutableListOf<HostKeyPrompt>()
        try {
            gate(asked, accept = false).verify(OfferedHostKey(endpoint, "ssh-ed25519", key))
            fail()
        } catch (rejected: SshFailure.HostKeyRejected) {
            assertEquals(SshFingerprint.of(key), rejected.prompt.fingerprint)
        }
        assertEquals(KnownHostsStore.Decision.Unknown, store.decision(endpoint, key))
    }

    @Test
    fun aKnownKeyPassesWithoutAskingAnyone() = runTest {
        store.record(endpoint, "ssh-ed25519", key, 5)
        val asked = mutableListOf<HostKeyPrompt>()
        gate(asked, accept = false).verify(OfferedHostKey(endpoint, "ssh-ed25519", key))
        assertTrue(asked.isEmpty())
    }

    @Test
    fun aChangedKeyStopsTheConnectionWithoutOfferingToTrustIt() = runTest {
        store.record(endpoint, "ssh-ed25519", key, 5)
        val asked = mutableListOf<HostKeyPrompt>()
        try {
            gate(asked, accept = true).verify(OfferedHostKey(endpoint, "ssh-rsa", byteArrayOf(9, 9)))
            fail()
        } catch (changed: SshFailure.HostKeyChanged) {
            assertEquals("ssh-ed25519", changed.known.algorithm)
            assertEquals("ssh-rsa", changed.presented.algorithm)
            assertEquals(SshFingerprint.of(key), changed.known.fingerprint)
        }
        assertTrue(asked.isEmpty())
        assertTrue(store.decision(endpoint, key) is KnownHostsStore.Decision.Match)
    }

    @Test
    fun forgettingAKeyMakesTheNextConnectionAFirstSight() {
        store.record(endpoint, "ssh-ed25519", key, 5)
        assertTrue(store.forget(endpoint))
        assertNull(store.host(endpoint))
        assertEquals(KnownHostsStore.Decision.Unknown, store.decision(endpoint, key))
    }

    @Test
    fun theSamePortOnAnotherEndpointIsAnotherServer() {
        store.record(endpoint, "ssh-ed25519", key, 5)
        assertEquals(KnownHostsStore.Decision.Unknown, store.decision(SshEndpoint("box.example.com", 2222), key))
    }

    @Test
    fun aKeyThatCannotBeSavedRefusesTheConnectionRatherThanTrustingItOnce() = runTest {
        secrets.writesSucceed = false
        try {
            gate(mutableListOf(), accept = true).verify(OfferedHostKey(endpoint, "ssh-ed25519", key))
            fail()
        } catch (failure: SshFailure.Transport) {
            assertFalse(failure.reason.isEmpty())
        }
    }

    @Test
    fun promptsAreShownOneAtATimeAndAnswersGoToTheirAskers() = runTest {
        val prompter = HostKeyPrompter()
        val first = HostKeyPrompt(endpoint, "ssh-ed25519", "SHA256:one")
        val second = HostKeyPrompt(endpoint, "ssh-rsa", "SHA256:two")
        val a = async { prompter.ask(first, "a") }
        val b = async { prompter.ask(second, "b") }
        advanceUntilIdle()
        assertEquals(first, prompter.current.value)
        prompter.answer(true)
        advanceUntilIdle()
        assertEquals(second, prompter.current.value)
        prompter.answer(false)
        advanceUntilIdle()
        assertTrue(a.await())
        assertFalse(b.await())
        assertNull(prompter.current.value)
    }

    @Test
    fun closingAnOwnerAnswersItsPromptsWithNo() = runTest {
        val prompter = HostKeyPrompter()
        val mine = async { prompter.ask(HostKeyPrompt(endpoint, "a", "x"), "mine") }
        val other = async { prompter.ask(HostKeyPrompt(endpoint, "b", "y"), "other") }
        advanceUntilIdle()
        prompter.refuse("mine")
        advanceUntilIdle()
        assertFalse(mine.await())
        assertEquals("y", prompter.current.value?.fingerprint)
        prompter.refuseAll()
        assertFalse(other.await())
    }
}
