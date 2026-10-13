package pl.dmq.peering.ssh

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.session.ports.SecretStore
import pl.dmq.peering.session.ports.StoredRead
import pl.dmq.peering.session.testing.FakeSecretStore
import pl.dmq.peering.session.testing.FixedRandom
import pl.dmq.peering.ssh.model.SshCredential
import pl.dmq.peering.ssh.model.SshHost
import pl.dmq.peering.ssh.model.SshHostLock
import pl.dmq.peering.ssh.model.SshKeyPair
import pl.dmq.peering.ssh.store.SshCredentialStore
import pl.dmq.peering.ssh.store.SshHostStore
import pl.dmq.peering.ssh.store.SshPasscodeStore

class StoresTest {
    private val secrets = FakeSecretStore()

    @Test
    fun hostsRoundTripAndKeepTheirForwards() {
        val host = SshHost("a", "Box", "box.example.com", 2222, "root", lock = SshHostLock.BIOMETRICS)
        assertTrue(SshHostStore(secrets).save(listOf(host)))
        assertEquals(listOf(host), SshHostStore(secrets).load())
    }

    @Test
    fun aHostSavedByAnOlderBuildWithFewerFieldsStillDecodes() {
        secrets.put("ssh.hosts", """[{"id":"a","hostname":"h","username":"u"}]""".encodeToByteArray())
        val host = SshHostStore(secrets).load().single()
        assertEquals(22, host.port)
        assertEquals(SshHostLock.OFF, host.lock)
        assertEquals("h", host.displayName)
    }

    @Test
    fun anUnknownLockValueFallsBackToOffRatherThanLosingTheList() {
        secrets.put("ssh.hosts", """[{"id":"a","hostname":"h","username":"u","lock":"retina"}]""".encodeToByteArray())
        assertEquals(SshHostLock.OFF, SshHostStore(secrets).load().single().lock)
    }

    @Test
    fun anUnreadableBlobLoadsEmptyAndIsNotOverwrittenByTheLoad() {
        secrets.put("ssh.hosts", "not json".encodeToByteArray())
        assertTrue(SshHostStore(secrets).load().isEmpty())
        assertEquals("not json", secrets.get("ssh.hosts")!!.decodeToString())
    }

    @Test
    fun recentlyConnectedServersComeFirstThenTheRestInTheOrderAdded() {
        val never1 = SshHost("1", hostname = "a", username = "u", createdAt = 1)
        val never2 = SshHost("2", hostname = "b", username = "u", createdAt = 2)
        val old = SshHost("3", hostname = "c", username = "u", createdAt = 3, lastConnectedAt = 10)
        val recent = SshHost("4", hostname = "d", username = "u", createdAt = 4, lastConnectedAt = 20)
        val ordered = SshHostStore.ordered(listOf(never2, old, never1, recent)).map { it.id }
        assertEquals(listOf("4", "3", "1", "2"), ordered)
    }

    @Test
    fun detailNamesThePortOnlyWhenItIsNotTheDefault() {
        assertEquals("root@h", SshHost("a", hostname = "h", username = "root").detail)
        assertEquals("root@h:2200", SshHost("a", hostname = "h", port = 2200, username = "root").detail)
    }

    @Test
    fun credentialsOfBothKindsRoundTripAndRemoveLeavesTheOthers() {
        val store = SshCredentialStore(secrets)
        val key = SshKeyPair("-----BEGIN-----", "ssh-ed25519 AAAA me", "phrase")
        assertTrue(store.save(SshCredential.Password("pw"), "a"))
        assertTrue(store.save(SshCredential.Key(key), "b"))
        assertEquals(SshCredential.Password("pw"), store.credential("a"))
        assertEquals(SshCredential.Key(key), store.credential("b"))
        assertTrue(store.remove("a"))
        assertFalse(store.hasCredential("a"))
        assertTrue(store.hasCredential("b"))
    }

    @Test
    fun aFailedWriteIsReportedSoTheCallerCanSayThePasswordWasNotRemembered() {
        secrets.writesSucceed = false
        assertFalse(SshCredentialStore(secrets).save(SshCredential.Password("pw"), "a"))
    }

    @Test
    fun keyLabelsRebuildFromTheBlob() {
        val key = SshKeyPair("p", "ssh-ed25519 AAAA old comment", null)
        assertEquals("old comment", key.comment)
        assertEquals("ssh-ed25519 AAAA phone", key.labelled(" phone ").publicKey)
        assertEquals("ssh-ed25519 AAAA", key.labelled("").publicKey)
        assertEquals("ssh-ed25519", key.algorithm)
    }

    @Test
    fun aPasscodeVerifiesOnlyTheSameDigitsOnlyForTheHostItWasSetFor() {
        val store = SshPasscodeStore(secrets, FixedRandom(7))
        assertTrue(store.set("123456", "a"))
        assertTrue(store.verify("123456", "a"))
        assertFalse(store.verify("123457", "a"))
        assertFalse(store.verify("123456", "b"))
        assertFalse(store.hasPasscode("b"))
    }

    @Test
    fun aPasscodeThatIsNotSixDigitsIsRefused() {
        val store = SshPasscodeStore(secrets, FixedRandom(7))
        assertFalse(store.set("12345", "a"))
        assertFalse(store.set("12345a", "a"))
        assertFalse(store.hasPasscode("a"))
    }

    @Test
    fun theStoredPasscodeIsNotTheDigits() {
        SshPasscodeStore(secrets, FixedRandom(7)).set("123456", "a")
        assertFalse(secrets.get("ssh.passcodes")!!.decodeToString().contains("123456"))
    }

    @Test
    fun removingAPasscodeLocksNobodyOutOfAnotherHost() {
        val store = SshPasscodeStore(secrets, FixedRandom(7))
        store.set("111111", "a")
        store.set("222222", "b")
        assertTrue(store.remove("a"))
        assertFalse(store.hasPasscode("a"))
        assertTrue(store.verify("222222", "b"))
    }

    @Test
    fun aReadThatFailsForNowIsNotRememberedAsAnEmptyList() {
        val inner = FakeSecretStore()
        SshHostStore(inner).save(listOf(SshHost("a", hostname = "h", username = "u")))
        var failing = true
        val flaky = object : SecretStore by inner {
            override fun read(key: String) = if (failing) StoredRead.Unreadable(permanent = false) else inner.read(key)
        }
        val store = SshHostStore(flaky)
        assertTrue(store.load().isEmpty())
        failing = false
        assertEquals(1, store.load().size)
    }

    @Test
    fun theValueIsReadFromStorageOnceAndThenKept() {
        val inner = FakeSecretStore()
        var reads = 0
        val counting = object : SecretStore by inner {
            override fun read(key: String): StoredRead {
                reads++
                return inner.read(key)
            }
        }
        val store = SshHostStore(counting)
        store.load()
        store.load()
        store.save(listOf(SshHost("a", hostname = "h", username = "u")))
        assertEquals(1, store.load().size)
        assertEquals(1, reads)
    }

    @Test
    fun aWriteThatDoesNotPersistLeavesTheOldValueInForce() {
        val store = SshHostStore(secrets)
        val first = SshHost("a", hostname = "h", username = "u")
        store.save(listOf(first))
        secrets.writesSucceed = false
        assertFalse(store.save(emptyList()))
        assertEquals(listOf(first), store.load())
    }
}
