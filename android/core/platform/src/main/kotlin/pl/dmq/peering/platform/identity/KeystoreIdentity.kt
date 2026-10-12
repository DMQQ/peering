package pl.dmq.peering.platform.identity

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.time.Duration
import java.time.Instant
import java.util.Date
import java.util.Locale
import java.util.UUID
import javax.security.auth.x500.X500Principal
import pl.dmq.peering.platform.net.TlsCredentials
import pl.dmq.peering.session.ports.DeviceIdentity
import pl.dmq.peering.session.ports.SecretStore

internal const val IDENTITY_ALIAS = "pl.dmq.peering.identity"
private const val ANDROID_KEY_STORE = "AndroidKeyStore"
private const val CLIENT_ID_KEY = "pl.dmq.peering.clientId"
private const val SIGNATURE_ALGORITHM = "SHA256withECDSA"
private const val CURVE = "secp256r1"
private val notBeforeMargin: Duration = Duration.ofHours(1)
private val validity: Duration = Duration.ofDays(3650)

/**
 * The device's P-256 key lives in the Android Keystore and never leaves it. The certificate is minted once with the
 * key, so peers pinning the key see the same value on every launch.
 */
class KeystoreIdentity(
    private val secrets: SecretStore,
    name: String,
) : DeviceIdentity, TlsCredentials {
    private val subject = "CN=${deviceName(name)}, O=Peering"
    private val keyStore: KeyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }

    private val chain: List<X509Certificate> by lazy {
        ensureKey()
        val certificates = keyStore.getCertificateChain(IDENTITY_ALIAS)
            ?: throw IllegalStateException("identity certificate missing after key creation")
        certificates.map { it as? X509Certificate ?: throw IllegalStateException("identity is not an X.509 certificate") }
    }

    override val clientId: String by lazy { storedClientId() ?: createClientId() }

    override val publicKey: ByteArray
        get() {
            val key = chain.first().publicKey as? ECPublicKey
                ?: throw IllegalStateException("identity key is not an EC key")
            return uncompressedPoint(key)
        }

    override fun certificateChain(): List<X509Certificate> = chain

    override fun privateKey(): PrivateKey {
        ensureKey()
        return keyStore.getKey(IDENTITY_ALIAS, null) as? PrivateKey
            ?: throw IllegalStateException("identity private key missing")
    }

    override fun sign(message: ByteArray): ByteArray =
        Signature.getInstance(SIGNATURE_ALGORITHM).run {
            initSign(privateKey())
            update(message)
            sign()
        }

    @Synchronized
    private fun ensureKey() {
        if (keyStore.containsAlias(IDENTITY_ALIAS)) {
            if (signsRawDigests()) return
            keyStore.deleteEntry(IDENTITY_ALIAS)
        }
        val now = Instant.now()
        val spec = KeyGenParameterSpec.Builder(IDENTITY_ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec(CURVE))
            .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_NONE)
            .setCertificateSubject(X500Principal(subject))
            .setCertificateNotBefore(Date.from(now.minus(notBeforeMargin)))
            .setCertificateNotAfter(Date.from(now.plus(validity)))
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEY_STORE)
            .apply { initialize(spec) }
            .generateKeyPair()
    }

    /** TLS 1.3 has Conscrypt sign with NONEwithECDSA, which a Keystore key only allows when it was made with DIGEST_NONE. Keys made earlier lack it and fail the handshake. */
    private fun signsRawDigests(): Boolean {
        val key = keyStore.getKey(IDENTITY_ALIAS, null) as? PrivateKey ?: return false
        val info = KeyFactory.getInstance(key.algorithm, ANDROID_KEY_STORE).getKeySpec(key, KeyInfo::class.java)
        return KeyProperties.DIGEST_NONE in info.digests
    }

    private fun storedClientId(): String? =
        secrets.get(CLIENT_ID_KEY)?.toString(Charsets.UTF_8)?.takeIf { it.isNotEmpty() }

    private fun createClientId(): String {
        val id = UUID.randomUUID().toString().uppercase(Locale.ROOT)
        val stored = secrets.put(CLIENT_ID_KEY, id.toByteArray(Charsets.UTF_8))
        check(stored) { "client id could not be stored" }
        return id
    }
}
