package pl.dmq.peering.platform.net

import java.net.Socket
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.X509Certificate
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager

internal const val CREDENTIAL_ALIAS = "identity"
private const val EC_KEY_TYPE = "EC"

/** The alias to present for the key types a peer asks for, or null when this device has no matching key. */
internal fun aliasForKeyTypes(requested: Array<out String>?): String? =
    if (requested.orEmpty().any { isEcKeyType(it) }) CREDENTIAL_ALIAS else null

private fun isEcKeyType(keyType: String?): Boolean = keyType.equals(EC_KEY_TYPE, ignoreCase = true)

/** Presents the device's single P-256 identity for client authentication and nothing else. */
class ClientKeyManager(private val credentials: TlsCredentials) : X509ExtendedKeyManager() {
    override fun chooseClientAlias(keyType: Array<String>?, issuers: Array<Principal>?, socket: Socket?): String? =
        aliasForKeyTypes(keyType)

    override fun chooseEngineClientAlias(keyType: Array<String>?, issuers: Array<Principal>?, engine: SSLEngine?): String? =
        aliasForKeyTypes(keyType)

    override fun getClientAliases(keyType: String?, issuers: Array<Principal>?): Array<String>? =
        if (isEcKeyType(keyType)) arrayOf(CREDENTIAL_ALIAS) else null

    override fun chooseServerAlias(keyType: String?, issuers: Array<Principal>?, socket: Socket?): String? = null

    override fun chooseEngineServerAlias(keyType: String?, issuers: Array<Principal>?, engine: SSLEngine?): String? = null

    override fun getServerAliases(keyType: String?, issuers: Array<Principal>?): Array<String>? = null

    override fun getCertificateChain(alias: String?): Array<X509Certificate>? =
        if (alias == CREDENTIAL_ALIAS) credentials.certificateChain().toTypedArray() else null

    override fun getPrivateKey(alias: String?): PrivateKey? =
        if (alias == CREDENTIAL_ALIAS) credentials.privateKey() else null
}
