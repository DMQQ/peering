package pl.dmq.peering

import pl.dmq.peering.platform.net.NetworkWatcher
import pl.dmq.peering.platform.net.OkHttpSignalling
import pl.dmq.peering.platform.net.TlsFactory
import pl.dmq.peering.session.connection.ClientConfig
import pl.dmq.peering.session.connection.ClientStateMachine
import pl.dmq.peering.session.connection.LivenessMonitor
import pl.dmq.peering.session.ports.Clock
import pl.dmq.peering.session.ports.Discovery
import pl.dmq.peering.session.ports.DeviceIdentity
import pl.dmq.peering.session.ports.PinStore
import pl.dmq.peering.session.ports.Random
import pl.dmq.peering.session.ports.Signalling
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.relay.ResilientSignalling

class SessionFactory(
    val identity: DeviceIdentity,
    val pins: PinStore,
    val random: Random,
    val clock: Clock,
    val discovery: Discovery,
    val tls: TlsFactory,
    val networkChanges: NetworkWatcher,
) {
    fun newClientStateMachine(config: ClientConfig) = ClientStateMachine(config, pins, random)

    fun newLivenessMonitor() = LivenessMonitor(clock)

    /** A relay connection that is opened on first use and opened again after it drops. */
    fun newRelaySignalling(): Signalling = ResilientSignalling(open = { OkHttpSignalling().apply { connect() } })

    fun newRelayConnect(signalling: Signalling) = RelayConnect(signalling, identity, clock)
}
