package pl.dmq.peering.ssh

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.testing.FakeSecretStore
import pl.dmq.peering.session.testing.FixedRandom
import pl.dmq.peering.ssh.hostkey.KnownHostsStore
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.model.SshHostLock
import pl.dmq.peering.ssh.session.OpenGate
import pl.dmq.peering.ssh.session.SshPhase
import pl.dmq.peering.ssh.session.SshServers
import pl.dmq.peering.ssh.store.SshCredentialStore
import pl.dmq.peering.ssh.store.SshHostStore
import pl.dmq.peering.ssh.store.SshPasscodeStore

@OptIn(ExperimentalCoroutinesApi::class)
class ServersTest {
    private val secrets = FakeSecretStore()
    private val transport = FakeTransport()
    private var clock = 100L
    private var ids = 0
    private val host = SshHost("h1", "Box", "box.example.com", 22, "root", createdAt = 1)

    private fun TestScope.servers() = SshServers(
        SshHostStore(secrets), SshCredentialStore(secrets), SshPasscodeStore(secrets, FixedRandom(3)),
        KnownHostsStore(secrets), transport, this, UnconfinedTestDispatcher(testScheduler), { clock }, { "id${ids++}" },
    )

    @Test
    fun savedServersSurviveARestart() = runTest {
        servers().save(host)
        assertEquals(listOf(host), servers().hosts.value)
    }

    @Test
    fun savingAnExistingServerReplacesItInsteadOfAddingASecond() = runTest {
        val servers = servers()
        servers.save(host)
        servers.save(host.copy(name = "Renamed"))
        assertEquals(listOf("Renamed"), servers.hosts.value.map { it.name })
    }

    @Test
    fun aServerWithASavedPasswordOpensStraightAway() = runTest {
        val servers = servers()
        servers.save(host)
        servers.apply(SshCredential.Password("pw"), host, remember = true)
        servers.requestOpen(host)
        advanceUntilIdle()
        assertEquals(host.id, servers.selected.value)
        assertEquals(SshCredential.Password("pw"), transport.seen!!.credential)
        assertEquals(SshPhase.Live, servers.live.value.single().session.phase.value)
        assertEquals(100L, servers.hosts.value.single().lastConnectedAt)
        servers.closeAll()
    }

    @Test
    fun aServerWithNothingSavedAsksForAPasswordAndKeepsItOnlyWhenToldTo() = runTest {
        val servers = servers()
        servers.save(host)
        servers.requestOpen(host)
        assertEquals(OpenGate.NeedsPassword(host), servers.gate.value)
        assertTrue(servers.live.value.isEmpty())
        servers.submitPassword("once", remember = false, host = host)
        advanceUntilIdle()
        assertNull(servers.gate.value)
        assertFalse(servers.hasStoredCredential(host))
        servers.closeAll()
        servers.requestOpen(host)
        servers.submitPassword("kept", remember = true, host = host)
        advanceUntilIdle()
        assertEquals(SshCredential.Password("kept"), servers.storedCredential(host))
        servers.closeAll()
    }

    @Test
    fun aKeyIsAlwaysKeptBecauseThereIsNothingToTypeAgain() = runTest {
        val servers = servers()
        servers.save(host)
        val key = pl.dmq.peering.ssh.model.SshKeyPair("p", "ssh-ed25519 AAAA")
        assertTrue(servers.apply(SshCredential.Key(key), host, remember = false))
        assertEquals(SshCredential.Key(key), servers.storedCredential(host))
    }

    @Test
    fun aPasscodeLockHoldsTheConnectionUntilTheRightDigitsArrive() = runTest {
        val servers = servers()
        val locked = host.copy(lock = SshHostLock.PASSCODE)
        servers.save(locked, passcode = "123456")
        servers.apply(SshCredential.Password("pw"), locked, remember = true)
        servers.requestOpen(locked)
        assertEquals(OpenGate.Locked(locked), servers.gate.value)
        servers.submitPasscode("000000", locked)
        assertEquals(OpenGate.Locked(locked, failures = 1), servers.gate.value)
        servers.submitPasscode("111111", locked)
        assertEquals(OpenGate.Locked(locked, failures = 2), servers.gate.value)
        assertTrue(servers.live.value.isEmpty())
        servers.submitPasscode("123456", locked)
        advanceUntilIdle()
        assertNull(servers.gate.value)
        assertEquals(1, servers.live.value.size)
        servers.closeAll()
    }

    @Test
    fun aLockedServerWhoseDeviceUnlockSucceedsOpens() = runTest {
        val servers = servers()
        val locked = host.copy(lock = SshHostLock.BIOMETRICS)
        servers.save(locked)
        servers.apply(SshCredential.Password("pw"), locked, remember = true)
        servers.requestOpen(locked)
        assertEquals(OpenGate.Locked(locked), servers.gate.value)
        servers.unlockedByDevice(locked)
        advanceUntilIdle()
        assertEquals(1, servers.live.value.size)
        servers.closeAll()
    }

    @Test
    fun aPasscodeLockWithNoPasscodeStoredFallsBackToUnlockedRatherThanLockingYouOut() = runTest {
        secrets.writesSucceed = false
        val servers = servers()
        servers.save(host.copy(lock = SshHostLock.PASSCODE), passcode = "123456")
        assertEquals(SshHostLock.OFF, servers.hosts.value.single().lock)
    }

    @Test
    fun aServerAlreadyOpenIsSelectedNotOpenedTwiceAndTheLockIsNotAskedAgain() = runTest {
        val servers = servers()
        val locked = host.copy(lock = SshHostLock.BIOMETRICS)
        servers.save(locked)
        servers.apply(SshCredential.Password("pw"), locked, remember = true)
        servers.unlockedByDevice(locked)
        advanceUntilIdle()
        servers.select(null)
        servers.requestOpen(locked)
        assertNull(servers.gate.value)
        assertEquals(1, servers.live.value.size)
        assertEquals(locked.id, servers.selected.value)
        servers.closeAll()
    }

    @Test
    fun deletingAServerForgetsItsSecretsAndItsKeyAndClosesItsConnection() = runTest {
        val servers = servers()
        servers.save(host)
        servers.apply(SshCredential.Password("pw"), host, remember = true)
        KnownHostsStore(secrets).record(host.endpoint, "ssh-ed25519", byteArrayOf(1), 1)
        servers.requestOpen(host)
        advanceUntilIdle()
        servers.delete(host)
        assertTrue(servers.hosts.value.isEmpty())
        assertTrue(servers.live.value.isEmpty())
        assertFalse(servers.hasStoredCredential(host))
        assertFalse(servers.isKeyKnown(host))
        assertTrue(transport.connectionClosed)
    }

    @Test
    fun forgettingAKeyIsTheOnlyWayPastAChangedOne() = runTest {
        val servers = servers()
        KnownHostsStore(secrets).record(host.endpoint, "ssh-ed25519", byteArrayOf(1), 1)
        assertTrue(servers.isKeyKnown(host))
        servers.forgetKey(host)
        assertFalse(servers.isKeyKnown(host))
    }

    @Test
    fun closingARowEndsItsPendingQuestionsWithNo() = runTest {
        val servers = servers()
        servers.save(host)
        servers.apply(SshCredential.Password("pw"), host, remember = true)
        servers.requestOpen(host)
        advanceUntilIdle()
        servers.close(host.id)
        assertNull(servers.selected.value)
        assertTrue(servers.live.value.isEmpty())
    }
}
