package pl.dmq.peering.ui

import pl.dmq.peering.feature.connect.ConnectVia
import pl.dmq.peering.session.controller.ConnectTarget
import pl.dmq.peering.session.controller.SessionPhase
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.ui.wiring.WakeBroadcast
import pl.dmq.peering.ui.wiring.pairedTarget
import pl.dmq.peering.widget.WidgetLink

/** Starts a session with a paired Mac, over the local network when it is seen there. */
internal fun FeatureWiring.connectPaired(hostId: String) {
    holder.connect(
        pairedTarget(hostId, discovery.addressOf(hostId), lanAddresses.addressOf(hostId), devicePrefs.prefs.value.allowsRelay),
    )
}

/** Whether a session is running that a link to end would cut off. */
internal fun FeatureWiring.hasLiveSession(): Boolean {
    val phase = holder.active.value?.controller?.state?.value?.phase ?: return false
    return phase !is SessionPhase.Failed && phase != SessionPhase.Ended
}

/** Opens the session already running with [hostId] when there is one, else starts a new one. */
internal fun FeatureWiring.connectOrResume(hostId: String) {
    val live = holder.active.value
    val phase = live?.controller?.state?.value?.phase
    val running = phase != null && phase !is SessionPhase.Failed && phase != SessionPhase.Ended
    if (live?.target?.hostId != hostId || !running) connectPaired(hostId)
}

/** Opens the computer a widget tap named, or the one last used. Only a paired computer is dialled: the link comes from outside the app. */
internal fun FeatureWiring.openFromWidget(link: WidgetLink) {
    if (link is WidgetLink.Disconnect) {
        holder.end()
        return
    }
    val hostId = link.targetHostId ?: holder.active.value?.target?.hostId ?: return
    if (hostId !in pins.hostIds()) return
    connectOrResume(hostId)
    if (link is WidgetLink.Chat) holder.active.value?.controller?.agentChat?.select(link.chatId)
    pendingSessionView.value = true
}

/** Dials a paired Mac over the one route the user chose. */
internal fun FeatureWiring.connectPairedVia(hostId: String, via: ConnectVia) {
    val target = when (via) {
        ConnectVia.Lan -> ConnectTarget.Paired(hostId, discovery.addressOf(hostId), lanAddresses.addressOf(hostId), relayAllowed = false)
        ConnectVia.Relay -> ConnectTarget.Paired(hostId, null, null, relayAllowed = true)
    }
    holder.connect(target)
}

/** Broadcasts the wake packet to each hardware address kept for [hostId]; null when none is kept, else how many were readable. */
internal fun FeatureWiring.wakeHost(hostId: String): Int? {
    val addresses = hostMacs.of(hostId).takeIf { it.isNotEmpty() } ?: return null
    return WakeBroadcast.send(addresses)
}

internal fun FeatureWiring.startPairing(hostId: String) = holder.connect(ConnectTarget.Pairing(hostId))

/** Dials a computer by address alone, the way for a network where it cannot be found by name. */
internal fun FeatureWiring.startPairingByAddress(address: PeerAddress) = holder.connect(ConnectTarget.Lan(address))
