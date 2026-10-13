package pl.dmq.peering.sshj

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class SshKeysTest {
    private fun problemOf(action: () -> Unit): SshKeyProblem {
        try {
            action()
        } catch (problem: SshKeyProblem) {
            return problem
        }
        throw AssertionError("expected a problem")
    }

    private fun keygen(vararg args: String): Pair<String, String>? {
        val dir = Files.createTempDirectory("keys").toFile()
        val file = File(dir, "k")
        val done = try {
            ProcessBuilder(listOf("ssh-keygen", "-q") + args + listOf("-f", file.path)).redirectErrorStream(true).start().waitFor()
        } catch (_: java.io.IOException) {
            return null
        }
        if (done != 0) return null
        return file.readText() to File(dir, "k.pub").readText().trim()
    }

    @Test
    fun aGeneratedKeyIsEd25519AndReadsBackToTheSamePublicLine() {
        val pair = SshKeys.generate("phone")
        assertEquals("ssh-ed25519", pair.algorithm)
        assertEquals("phone", pair.comment)
        assertTrue(pair.privateKey.startsWith("-----BEGIN OPENSSH PRIVATE KEY-----"))
        assertEquals(pair.publicKey.substringBefore(" phone"), SshKeys.read(pair.privateKey, null).publicKey)
    }

    @Test
    fun twoGeneratedKeysDiffer() {
        assertTrue(SshKeys.generate().publicKey != SshKeys.generate().publicKey)
    }

    @Test
    fun anImportedOpenSshKeyYieldsTheLineSshKeygenPrints() {
        val (private, public) = keygen("-t", "ed25519", "-N", "", "-C", "me@laptop") ?: return assumeTrue(false)
        assertEquals(public.substringBeforeLast(" "), SshKeys.read(private, null).publicKey)
    }

    @Test
    fun anImportedRsaKeyIsAccepted() {
        val (private, public) = keygen("-t", "rsa", "-b", "2048", "-N", "") ?: return assumeTrue(false)
        val pair = SshKeys.read(private, null)
        assertEquals("ssh-rsa", pair.algorithm)
        assertEquals(public.split(" ")[1], pair.publicKey.split(" ")[1])
    }

    @Test
    fun aKeyWithAPassphraseNeedsItAndRefusesAWrongOne() {
        val (private, public) = keygen("-t", "ed25519", "-N", "secret") ?: return assumeTrue(false)
        assertTrue(problemOf { SshKeys.read(private, null) } is SshKeyProblem.PassphraseNeeded)
        assertTrue(problemOf { SshKeys.read(private, "guess") } is SshKeyProblem.PassphraseWrong)
        val pair = SshKeys.read(private, "secret")
        assertEquals("secret", pair.passphrase)
        assertEquals(public.split(" ")[1], pair.publicKey.split(" ")[1])
    }

    @Test
    fun aPublicKeyPastedForAPrivateOneIsRecognisedAsSuch() {
        assertTrue(problemOf { SshKeys.read("ssh-ed25519 AAAAC3Nza me@laptop", null) } is SshKeyProblem.NotAPrivateKey)
    }

    @Test
    fun aDamagedKeyIsMalformedRatherThanACrash() {
        val broken = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"
        assertTrue(problemOf { SshKeys.read(broken, null) } is SshKeyProblem.Malformed)
    }
}
