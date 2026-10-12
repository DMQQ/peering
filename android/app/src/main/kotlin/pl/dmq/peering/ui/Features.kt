package pl.dmq.peering.ui

import android.content.SharedPreferences
import kotlinx.coroutines.CoroutineScope
import pl.dmq.peering.AppGraph
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.feature.scan.CameraQrSource
import pl.dmq.peering.ui.nav.ScreenRegistry
import pl.dmq.peering.ui.wiring.DiscoveryHostSource
import pl.dmq.peering.ui.wiring.PinTrustedHosts
import pl.dmq.peering.ui.wiring.PreferencesComposerDrafts
import pl.dmq.peering.ui.wiring.PreferencesFolderRecents
import pl.dmq.peering.ui.wiring.PreferencesKeyValueStore
import pl.dmq.peering.ui.wiring.PreferencesFirstRunStore
import pl.dmq.peering.ui.wiring.PreferencesSettingsStore
import pl.dmq.peering.ui.wiring.SessionHolder
import pl.dmq.peering.billing.PlayBilling
import pl.dmq.peering.ui.wiring.PeeringQualitySource
import pl.dmq.peering.ui.wiring.SessionPortsFactory
import pl.dmq.peering.ui.wiring.SessionPresence
import pl.dmq.peering.ui.wiring.SurfacePicture
import pl.dmq.peering.ui.wiring.pairedTarget
import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.hosts.PersistedHostDirectory
import pl.dmq.peering.session.relay.PresenceWatch

/** The adapters the screens share, built once for the process. [install] points the tab slots at the real screens. */
internal class FeatureWiring(graph: AppGraph, scope: CoroutineScope, preferences: SharedPreferences) {
    val picture = SurfacePicture()
    val qrSource = CameraQrSource()
    val clock: Clock = graph.sessions.clock
    val drafts = PreferencesComposerDrafts(preferences)
    val folderRecents = PreferencesFolderRecents(preferences)
    val firstRun = PreferencesFirstRunStore(preferences)
    val settings = PreferencesSettingsStore(preferences)
    val hostNames = PersistedHostDirectory(PreferencesKeyValueStore(preferences))
    val trusted = PinTrustedHosts(graph.sessions.pins, hostNames)
    val discovery = DiscoveryHostSource(graph.sessions.discovery, graph.sessions.pins, hostNames, scope)
    val billing = PlayBilling(graph.applicationContext, scope) { graph.sessions.identity.publicKey }.also { it.connect() }
    val holder = SessionHolder(
        SessionPortsFactory(
            graph.sessions,
            picture,
            SessionHistory.fromJson(EMPTY_HISTORY),
            PeeringQualitySource(settings, billing),
            billing,
        ),
        hostNames,
        scope,
    )
    private val relayPresence = PresenceWatch(
        relay = graph.sessions.newRelayConnect(graph.sessions.newRelaySignalling()),
        hostIds = { graph.sessions.pins.hostIds() },
        clock = graph.sessions.clock,
        scope = scope,
    )
    val presence = SessionPresence(holder, relayPresence)

    /** Starts a session with a paired Mac, over the local network when it is seen there. */
    fun connectPaired(hostId: String) {
        holder.connect(pairedTarget(hostId, discovery.addressOf(hostId)))
    }

    fun startPairing(hostId: String) = holder.connect(ConnectTarget.Pairing(hostId))

    fun install() {
        ScreenRegistry.connect = { ConnectTab(this) }
        ScreenRegistry.sessions = { SessionTab(this) }
        ScreenRegistry.settings = { SettingsTab(this) }
    }

    private companion object {
        const val EMPTY_HISTORY = "[]"
    }
}
