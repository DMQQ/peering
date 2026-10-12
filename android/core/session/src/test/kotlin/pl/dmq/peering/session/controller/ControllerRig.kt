package pl.dmq.peering.session.controller

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.TestCoroutineScheduler
import pl.dmq.peering.session.flows.ScriptedPairingHost
import pl.dmq.peering.session.flows.TestSchedulerClock
import pl.dmq.peering.session.history.SessionHistory
import pl.dmq.peering.session.ports.DiscoveredHost
import pl.dmq.peering.session.ports.Discovery
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.testing.FakeDatagramTransport
import pl.dmq.peering.session.testing.FakeIdentity
import pl.dmq.peering.session.testing.FakePinStore
import pl.dmq.peering.session.relay.RelayEntitlement
import pl.dmq.peering.session.testing.FakeSignalling
import pl.dmq.peering.session.testing.FakeVideoSink
import pl.dmq.peering.session.testing.FixedRandom

/**
 * A [SessionController] wired to fakes: the [mac] answers on every control connection the controller opens, the relay
 * is a [FakeSignalling] and a [FakeDatagramTransport], and discovery finds the host on a LAN address.
 */
class ControllerRig(
    scope: CoroutineScope,
    scheduler: TestCoroutineScheduler,
    val target: ConnectTarget,
    val mac: ScriptedMac = ScriptedMac(),
    val pins: FakePinStore = FakePinStore(mapOf(ScriptedPairingHost.HOST_ID to ScriptedPairingHost.HOST_KEY)),
    val entitlement: RelayEntitlement = RelayEntitlement(),
) {
    val routes = mutableListOf<ControlRoute>()

    /** When false, every control connection attempt fails, as it does when the Mac is off the network. */
    var reachable = true

    /** Direct addresses that answer with a refusal, as a stale advertised port does. */
    val refusing = mutableSetOf<PeerAddress>()
    val sink = FakeVideoSink()
    val signalling = FakeSignalling()
    val datagrams = FakeDatagramTransport()
    val history = SessionHistory()
    val downloads = mutableMapOf<Long, ByteArray>()
    val clock = TestSchedulerClock(scheduler)

    val ports = SessionPorts(
        identity = FakeIdentity(CLIENT_ID),
        clientName = CLIENT_NAME,
        pins = pins,
        random = FixedRandom(1),
        clock = clock,
        control = ControlConnector { route ->
            routes += route
            check(reachable) { "the host is not reachable" }
            if (route is ControlRoute.Direct && route.address in refusing) throw java.net.ConnectException("refused")
            mac.newConnection()
        },
        discovery = object : Discovery {
            override fun hosts(): Flow<DiscoveredHost> = flowOf(
                DiscoveredHost(ScriptedPairingHost.HOST_ID, HOST_NAME, protocolVersion = 1, address = LAN_ADDRESS),
            )
        },
        sink = sink,
        downloads = DownloadWriter { offset, bytes -> downloads[offset] = bytes },
        relay = RelayPorts(signalling, datagrams) { entitlement },
    )

    val controller = SessionController(scope, target, ports, history)

    companion object {
        const val CLIENT_ID = "11111111-2222-4333-8444-555555555555"
        const val CLIENT_NAME = "Phone"
        const val HOST_NAME = "Studio"
        val LAN_ADDRESS = PeerAddress("192.0.2.10", 7000)
    }
}
