package pl.dmq.peering

import android.content.Context
import android.net.ConnectivityManager
import android.net.nsd.NsdManager
import android.net.wifi.WifiManager
import android.os.Build
import java.io.File
import pl.dmq.peering.platform.discovery.MulticastLease
import pl.dmq.peering.platform.discovery.NsdDiscovery
import pl.dmq.peering.platform.identity.KeystoreIdentity
import pl.dmq.peering.platform.net.NetworkWatcher
import pl.dmq.peering.platform.net.TlsFactory
import pl.dmq.peering.platform.store.BlobStore
import pl.dmq.peering.platform.store.KeystoreBlobStore
import pl.dmq.peering.platform.store.PinStoreImpl
import pl.dmq.peering.session.ports.PinStore
import pl.dmq.peering.session.ports.SecretStore
import pl.dmq.peering.ui.wiring.PreferenceWrites

// Every platform object is built on first use, so JVM tests of view models never reach Android.
class AppGraph(context: Context) {
    private val appContext = context.applicationContext

    val applicationContext: Context get() = appContext

    private val secureDirectory: File by lazy {
        File(appContext.filesDir, "secure").apply { mkdirs() }
    }

    private val blobs: BlobStore by lazy { KeystoreBlobStore(secureDirectory) }

    private val secrets: SecretStore by lazy { BlobSecretStore(blobs) }

    private val keystoreIdentity: KeystoreIdentity by lazy {
        KeystoreIdentity(secrets, Build.MODEL.orEmpty())
    }

    private val pinStore: PinStoreImpl by lazy { PinStoreImpl(blobs) }

    private val pins: PinStore get() = pinStore

    /** True once if the stored pairings could not be read; reads the keystore, so call it off the main thread. */
    fun takePairingsUnreadable(): Boolean = pinStore.takeReadFailure()

    private val tls: TlsFactory by lazy { TlsFactory(keystoreIdentity) }

    private val networkWatcher: NetworkWatcher by lazy {
        NetworkWatcher(appContext.getSystemService(ConnectivityManager::class.java))
    }

    private val discovery: NsdDiscovery by lazy {
        val wifi = appContext.getSystemService(WifiManager::class.java)
        NsdDiscovery(appContext.getSystemService(NsdManager::class.java), MulticastLease(wifi))
    }

    internal val preferenceWrites: PreferenceWrites by lazy { PreferenceWrites.onBackgroundThread() }

    val sessions: SessionFactory by lazy {
        SessionFactory(
            identity = keystoreIdentity,
            pins = pins,
            random = SecureRandomSource(),
            clock = AndroidClock(),
            discovery = discovery,
            tls = tls,
            networkChanges = networkWatcher,
        )
    }
}
