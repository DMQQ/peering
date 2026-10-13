package pl.dmq.peering.sshj

import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.common.KeyType
import net.schmizz.sshj.userauth.password.PasswordUtils
import org.bouncycastle.crypto.generators.Ed25519KeyPairGenerator
import org.bouncycastle.crypto.params.Ed25519KeyGenerationParameters
import org.bouncycastle.crypto.util.OpenSSHPrivateKeyUtil
import pl.dmq.peering.ssh.model.SshKeyPair
import java.io.IOException
import java.security.PublicKey
import java.security.SecureRandom
import java.util.Base64

/** Why a key was refused; the app turns each into the sentence that tells the user what to do about it. */
sealed class SshKeyProblem(message: String) : Exception(message) {
    class NotAPrivateKey : SshKeyProblem("not a private key")

    class Malformed(val reason: String) : SshKeyProblem(reason)

    class PassphraseNeeded : SshKeyProblem("passphrase needed")

    class PassphraseWrong : SshKeyProblem("passphrase wrong")
}

/** Making and reading keys. The public line is derived from the private key's own bytes, so it always matches what a server compares. */
object SshKeys {
    private const val PEM_HEADER = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private const val PEM_FOOTER = "-----END OPENSSH PRIVATE KEY-----"
    private const val PEM_LINE = 70

    /** ed25519, as OpenSSH defaults to, with no passphrase: the private half never leaves the sealed store. */
    fun generate(comment: String = ""): SshKeyPair {
        SshProviders.install()
        val generator = Ed25519KeyPairGenerator()
        generator.init(Ed25519KeyGenerationParameters(SecureRandom()))
        val pair = generator.generateKeyPair()
        val body = Base64.getEncoder().encodeToString(OpenSSHPrivateKeyUtil.encodePrivateKey(pair.private))
        val pem = (listOf(PEM_HEADER) + body.chunked(PEM_LINE) + PEM_FOOTER).joinToString("\n", postfix = "\n")
        return read(pem, null).labelled(comment)
    }

    /** Reads a pasted or imported private key. Throws [SshKeyProblem]. */
    fun read(text: String, passphrase: String?): SshKeyPair {
        SshProviders.install()
        val pem = text.trim()
        if (!pem.contains("PRIVATE KEY")) throw SshKeyProblem.NotAPrivateKey()
        val finder = passphrase?.takeIf { it.isNotEmpty() }?.let { PasswordUtils.createOneOff(it.toCharArray()) }
        val provider = try {
            SSHClient().loadKeys(pem, null, finder)
        } catch (failure: IOException) {
            throw problemOf(failure, passphrase)
        }
        val publicKey = try {
            provider.public
        } catch (failure: IOException) {
            throw problemOf(failure, passphrase)
        }
        return SshKeyPair(pem + "\n", line(publicKey), passphrase?.takeIf { it.isNotEmpty() })
    }

    private fun line(key: PublicKey): String {
        val blob = Buffer.PlainBuffer().putPublicKey(key).compactData
        return "${KeyType.fromKey(key)} ${Base64.getEncoder().encodeToString(blob)}"
    }

    private fun problemOf(failure: IOException, passphrase: String?): SshKeyProblem {
        val said = generateSequence<Throwable>(failure) { it.cause }.joinToString(" ") { "${it.javaClass.simpleName} ${it.message}" }
        return when {
            said.contains("KeyDecryptionFailed") || said.contains("decrypt", ignoreCase = true) ->
                if (passphrase.isNullOrEmpty()) SshKeyProblem.PassphraseNeeded() else SshKeyProblem.PassphraseWrong()
            said.contains("password", ignoreCase = true) && passphrase.isNullOrEmpty() -> SshKeyProblem.PassphraseNeeded()
            else -> SshKeyProblem.Malformed(failure.message ?: "unrecognised format")
        }
    }
}
