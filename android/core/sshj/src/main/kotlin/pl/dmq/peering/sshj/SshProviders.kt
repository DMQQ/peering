package pl.dmq.peering.sshj

import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.Security

object SshProviders {
    private var installed = false

    /**
     * Android ships a stripped-down provider under the name BC that lacks the algorithms sshj asks it for (ed25519,
     * curve25519 key exchange), and a provider cannot be registered twice under one name. The platform's is replaced by
     * the full one before sshj first looks it up.
     */
    @Synchronized
    fun install() {
        if (installed) return
        Security.removeProvider(BouncyCastleProvider.PROVIDER_NAME)
        Security.insertProviderAt(BouncyCastleProvider(), 1)
        installed = true
    }
}
