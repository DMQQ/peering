package pl.dmq.peering.ui

import android.content.SharedPreferences
import kotlinx.coroutines.CoroutineScope
import pl.dmq.peering.AppGraph
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.ui.nav.ScreenRegistry
import pl.dmq.peering.ui.wiring.DiscoveryHostSource
import pl.dmq.peering.ui.wiring.PinTrustedHosts
import pl.dmq.peering.ui.wiring.PreferencesComposerDrafts
import pl.dmq.peering.ui.wiring.PreferencesFirstRunStore
import pl.dmq.peering.ui.wiring.PreferencesSettingsStore
import pl.dmq.peering.ui.wiring.SessionHolder
import pl.dmq.peering.ui.wiring.SessionPortsFactory
import pl.dmq.peering.ui.wiring.SessionPresence
import pl.dmq.peering.ui.wiring.SurfacePicture
import pl.dmq.peering.ui.wiring.pairedTarget
import pl.dmq.peering.session.controller.ConnectTarget

/** The adapters the screens share, built once for the process. [install] points the tab slots at the real screens. */
internal class FeatureWiring(graph: AppGraph, scope: CoroutineScope, preferences: SharedPreferences) {
    val picture = SurfacePicture()
    val clock: Clock = graph.sessions.clock
    val drafts = PreferencesComposerDrafts(preferences)
    val firstRun = PreferencesFirstRunStore(preferences)
    val settings = PreferencesSettingsStore(preferences)
    val trusted = PinTrustedHosts(graph.sessions.pins)
    val discovery = DiscoveryHostSource(graph.sessions.discovery, graph.sessions.pins, scope)
    val holder = SessionHolder(SessionPortsFactory(graph.sessions, picture, SessionHistory.fromJson(EMPTY_HISTORY)), scope)
    val presence = SessionPresence(holder)

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
