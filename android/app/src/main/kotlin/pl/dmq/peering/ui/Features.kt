package pl.dmq.peering.ui

import pl.dmq.peering.feature.connect.ConnectUiState
import pl.dmq.peering.feature.ssh.ServersTab
import pl.dmq.peering.feature.ssh.SshHub
import android.content.SharedPreferences
import android.os.Build
import pl.dmq.peering.ui.wiring.PreferencesDevicePreferences
import pl.dmq.peering.ui.wiring.PreferencesMacroStore
import java.time.ZoneId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import pl.dmq.peering.AppGraph
import pl.dmq.peering.background.BackgroundWiring
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import pl.dmq.peering.widget.WidgetPublisher
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import pl.dmq.peering.ui.wiring.PersistedSessionRecords
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.feature.scan.CameraQrSource
import pl.dmq.peering.feature.onboarding.FaqScreen
import pl.dmq.peering.ui.nav.ScreenRegistry
import pl.dmq.peering.platform.audio.ComputerSound
import pl.dmq.peering.ui.wiring.ComputerSoundSink
import pl.dmq.peering.ui.wiring.ConnectivityNetworkSource
import pl.dmq.peering.ui.wiring.follow
import pl.dmq.peering.ui.wiring.processForeground
import pl.dmq.peering.feature.whatsnew.WhatsNewStore
import pl.dmq.peering.ui.wiring.DevicePower
import pl.dmq.peering.ui.wiring.DiscoveryHostSource
import pl.dmq.peering.ui.wiring.MemoryPressure
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
import pl.dmq.peering.session.clipboard.ClipboardHistory
import pl.dmq.peering.session.hosts.HostMacAddresses
import pl.dmq.peering.session.hosts.PersistedHostDirectory
import pl.dmq.peering.session.hosts.RememberedLanAddresses
import pl.dmq.peering.session.relay.PresenceWatch
import pl.dmq.peering.session.relay.ReferralClient
import pl.dmq.peering.feature.settings.InvitePresenter
import pl.dmq.peering.ui.wiring.RelayInviteService

/** The adapters the screens share, built once for the process. [install] points the tab slots at the real screens. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class FeatureWiring(graph: AppGraph, scope: CoroutineScope, preferences: SharedPreferences) {
    private val writes = graph.preferenceWrites
    val picture = SurfacePicture()
    private val power = DevicePower(graph.applicationContext)

    /** Built when the Servers tab first opens: it reads sealed storage, which the first screen has no use for. */
    val ssh by lazy { SshHub(graph, scope, preferences) }

    /** What the Connect tab showed last, so coming back to it starts from that and not from an empty list. */
    var lastConnectState: ConnectUiState? = null
    val qrSource = CameraQrSource()
    val network = ConnectivityNetworkSource(graph.applicationContext)
    val clock: Clock = graph.sessions.clock
    val drafts = PreferencesComposerDrafts(preferences)
    val folderRecents = PreferencesFolderRecents(preferences)
    val firstRun = PreferencesFirstRunStore(preferences)
    val settings = PreferencesSettingsStore(preferences)
    val whatsNew = WhatsNewStore(PreferencesKeyValueStore(preferences, writes))
    val devicePrefs = PreferencesDevicePreferences(preferences, Build.MODEL.orEmpty())
    val macros = PreferencesMacroStore(preferences)
    val deviceId: String = graph.sessions.identity.clientId
    val hostNames = PersistedHostDirectory(PreferencesKeyValueStore(preferences, writes))
    val trusted = PinTrustedHosts(graph.sessions.pins, hostNames)
    val hostMacs = HostMacAddresses(PreferencesKeyValueStore(preferences, writes))
    val lanAddresses = RememberedLanAddresses(PreferencesKeyValueStore(preferences, writes))
    val aliases = HostAliases(PreferencesKeyValueStore(preferences, writes)) { graph.sessions.pins.hostIds().toSet() }
    val discovery = DiscoveryHostSource(graph.sessions.discovery, graph.sessions.pins, hostNames, lanAddresses, aliases, scope, hostMacs)
    val billing = PlayBilling(graph.applicationContext, scope) { graph.sessions.identity.publicKey }.also { it.connect() }
    val sessionRecords = PersistedSessionRecords.load(preferences, writes)
    val relayAllowance = RelayAllowanceTracker(
        PreferencesRelayUsageStore(preferences, writes),
        graph.sessions.clock,
        ZoneId.systemDefault(),
        billing.paidRelay,
        scope,
    )
    private val sound = ComputerSound(graph.applicationContext).also { it.follow(scope, devicePrefs.prefs, processForeground()) }
    val holder = SessionHolder(
        SessionPortsFactory(
            graph.sessions,
            ComputerSoundSink(picture, sound),
            sessionRecords.history,
            PeeringQualitySource(settings, billing, power),
            billing,
            lanAddresses,
            ClipboardHistory(PreferencesKeyValueStore(preferences, writes)),
            relayAllowance::relayReportedRemaining,
        ) { devicePrefs.prefs.value.deviceName },
        hostNames,
        scope,
        hostMacs,
    )
    val background = BackgroundWiring(graph.applicationContext, scope, preferences, holder.active, devicePrefs)

    init {
        scope.launch { relayAllowance.trackSessions(relayInUse(holder.active)) }
        scope.launch {
            power.saving.drop(1).collect { holder.active.value?.controller?.powerSavingChanged() }
        }
        MemoryPressure(graph.applicationContext) { holder.active.value?.controller?.trimMemory() }
    }

    private val relayPresence = PresenceWatch(
        relay = graph.sessions.newRelayConnect(graph.sessions.newRelaySignalling()),
        hostIds = { graph.sessions.pins.hostIds() },
        clock = graph.sessions.clock,
        scope = scope,
    )
    val invites = InvitePresenter(
        RelayInviteService(ReferralClient(graph.sessions.newRelaySignalling(), graph.sessions.identity, graph.sessions.clock)),
        scope,
    )
    val presence = SessionPresence(holder, relayPresence)
    internal val pins = graph.sessions.pins

    /** Set by a widget tap that asked for a session; the Connect tab shows it and clears the flag. */
    val pendingSessionView = MutableStateFlow(false)

    init {
        WidgetPublisher(graph.applicationContext, scope, clock)
            .start(trusted.trustedHosts(), presence.connectedHostId(), presence.onlineHostIds(), holder.active)
        scope.launch {
            holder.active
                .flatMapLatest { session -> session?.controller?.state?.map { it.phase } ?: flowOf(null) }
                .distinctUntilChanged()
                .collect { sessionRecords.refresh() }
        }
    }

    fun install() {
        ScreenRegistry.connect = { ConnectTab(this) }
        ScreenRegistry.servers = { ServersTab(ssh) }
        ScreenRegistry.sessions = { SessionTab(this) }
        ScreenRegistry.faq = { FaqScreen() }
        ScreenRegistry.settings = { SettingsTab(this) }
    }
}
