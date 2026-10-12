package pl.dmq.peering.ui

import android.content.SharedPreferences
import android.os.Build
import pl.dmq.peering.ui.wiring.PreferencesDevicePreferences
import pl.dmq.peering.ui.wiring.PreferencesMacroStore
import java.time.ZoneId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import pl.dmq.peering.AppGraph
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.ui.wiring.PersistedSessionRecords
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.feature.scan.CameraQrSource
import pl.dmq.peering.feature.onboarding.FaqScreen
import pl.dmq.peering.ui.nav.ScreenRegistry
import pl.dmq.peering.ui.wiring.ConnectivityNetworkSource
import pl.dmq.peering.feature.connect.ConnectVia
import pl.dmq.peering.ui.wiring.DiscoveryHostSource
import pl.dmq.peering.ui.wiring.HostAliases
import pl.dmq.peering.ui.wiring.PinTrustedHosts
import pl.dmq.peering.ui.wiring.PreferencesComposerDrafts
import pl.dmq.peering.ui.wiring.PreferencesFolderRecents
import pl.dmq.peering.ui.wiring.PreferencesKeyValueStore
import pl.dmq.peering.ui.wiring.PreferencesFirstRunStore
import pl.dmq.peering.ui.wiring.PreferencesSettingsStore
import pl.dmq.peering.ui.wiring.SessionHolder
import pl.dmq.peering.billing.PlayBilling
import pl.dmq.peering.feature.paywall.RelayAllowanceTracker
import pl.dmq.peering.ui.wiring.PeeringQualitySource
import pl.dmq.peering.ui.wiring.PreferencesRelayUsageStore
import pl.dmq.peering.ui.wiring.relayInUse
import pl.dmq.peering.ui.wiring.SessionPortsFactory
import pl.dmq.peering.ui.wiring.SessionPresence
import pl.dmq.peering.ui.wiring.SurfacePicture
import pl.dmq.peering.ui.wiring.pairedTarget
import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.clipboard.ClipboardHistory
import pl.dmq.peering.session.hosts.PersistedHostDirectory
import pl.dmq.peering.session.hosts.RememberedLanAddresses
import pl.dmq.peering.session.relay.PresenceWatch

/** The adapters the screens share, built once for the process. [install] points the tab slots at the real screens. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class FeatureWiring(graph: AppGraph, scope: CoroutineScope, preferences: SharedPreferences) {
    val picture = SurfacePicture()
    val qrSource = CameraQrSource()
    val network = ConnectivityNetworkSource(graph.applicationContext)
    val clock: Clock = graph.sessions.clock
    val drafts = PreferencesComposerDrafts(preferences)
    val folderRecents = PreferencesFolderRecents(preferences)
    val firstRun = PreferencesFirstRunStore(preferences)
    val settings = PreferencesSettingsStore(preferences)
    val devicePrefs = PreferencesDevicePreferences(preferences, Build.MODEL.orEmpty())
    val macros = PreferencesMacroStore(preferences)
    val deviceId: String = graph.sessions.identity.clientId
    val hostNames = PersistedHostDirectory(PreferencesKeyValueStore(preferences))
    val trusted = PinTrustedHosts(graph.sessions.pins, hostNames)
    val lanAddresses = RememberedLanAddresses(PreferencesKeyValueStore(preferences))
    val aliases = HostAliases(PreferencesKeyValueStore(preferences)) { graph.sessions.pins.hostIds().toSet() }
    val discovery = DiscoveryHostSource(graph.sessions.discovery, graph.sessions.pins, hostNames, lanAddresses, aliases, scope)
    val billing = PlayBilling(graph.applicationContext, scope) { graph.sessions.identity.publicKey }.also { it.connect() }
    val sessionRecords = PersistedSessionRecords.load(preferences)
    val holder = SessionHolder(
        SessionPortsFactory(
            graph.sessions,
            picture,
            sessionRecords.history,
            PeeringQualitySource(settings, billing),
            billing,
            lanAddresses,
            ClipboardHistory(PreferencesKeyValueStore(preferences)),
        ) { devicePrefs.prefs.value.deviceName },
        hostNames,
        scope,
    )
    private val relayPresence = PresenceWatch(
        relay = graph.sessions.newRelayConnect(graph.sessions.newRelaySignalling()),
        hostIds = { graph.sessions.pins.hostIds() },
        clock = graph.sessions.clock,
        scope = scope,
    )
    val relayAllowance = RelayAllowanceTracker(
        PreferencesRelayUsageStore(preferences),
        graph.sessions.clock,
        ZoneId.systemDefault(),
        billing.paidRelay,
        scope,
    ).also { tracker -> scope.launch { tracker.trackSessions(relayInUse(holder.active)) } }
    val presence = SessionPresence(holder, relayPresence)

    init {
        scope.launch {
            holder.active
                .flatMapLatest { session -> session?.controller?.state?.map { it.phase } ?: flowOf(null) }
                .distinctUntilChanged()
                .collect { sessionRecords.refresh() }
        }
    }

    /** Starts a session with a paired Mac, over the local network when it is seen there. */
    fun connectPaired(hostId: String) {
        holder.connect(
            pairedTarget(hostId, discovery.addressOf(hostId), lanAddresses.addressOf(hostId), devicePrefs.prefs.value.allowsRelay),
        )
    }

    /** Opens the session already running with [hostId] when there is one, else starts a new one. */
    fun connectOrResume(hostId: String) {
        val live = holder.active.value
        val phase = live?.controller?.state?.value?.phase
        val running = phase != null && phase !is SessionPhase.Failed && phase != SessionPhase.Ended
        if (live?.target?.hostId != hostId || !running) connectPaired(hostId)
    }

    /** Dials a paired Mac over the one route the user chose. */
    fun connectPairedVia(hostId: String, via: ConnectVia) {
        val target = when (via) {
            ConnectVia.Lan -> ConnectTarget.Paired(hostId, discovery.addressOf(hostId), lanAddresses.addressOf(hostId), relayAllowed = false)
            ConnectVia.Relay -> ConnectTarget.Paired(hostId, null, null, relayAllowed = true)
        }
        holder.connect(target)
    }

    fun startPairing(hostId: String) = holder.connect(ConnectTarget.Pairing(hostId))

    /** Dials a computer by address alone, the way for a network where it cannot be found by name. */
    fun startPairingByAddress(address: PeerAddress) = holder.connect(ConnectTarget.Lan(address))

    fun install() {
        ScreenRegistry.connect = { ConnectTab(this) }
        ScreenRegistry.sessions = { SessionTab(this) }
        ScreenRegistry.faq = { FaqScreen() }
        ScreenRegistry.settings = { SettingsTab(this) }
    }
}
