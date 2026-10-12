package pl.dmq.peering.session.controller

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
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
    nobodyDiscovered: Boolean = false,
    discoveryDelayMillis: Long = 0,
) {
    val routes = mutableListOf<ControlRoute>()

    /** Whether discovery lists the host; a test sets it to move the host onto the phone's network. */
    var hostVisible = !nobodyDiscovered

    /** Where discovery finds the host; a test sets it to move the host to another address. */
    var hostAddress = LAN_ADDRESS

    /** When true, starting discovery throws, as NsdManager does with Wi-Fi off. */
    var discoveryFails = false

    /** What the controller reported to its debug log. */
    val logged = mutableListOf<String>()

    /** The local addresses the controller reported reaching hosts at. */
    val reachedOnLan = mutableMapOf<String, PeerAddress>()

    /** The routes dialled for control connections: every one except the picture lane. */
    val controlRoutes: List<ControlRoute> get() = routes.filter { it !is ControlRoute.Video }

    /** When false, every control connection attempt fails, as it does when the Mac is off the network. */
    var reachable = true

    /** Direct addresses that answer with a refusal, as a stale advertised port does. */
    val refusing = mutableSetOf<PeerAddress>()

    /** When false, a picture connection cannot be opened, as when the host refuses it. */
    var videoReachable = true

    /** The picture connections opened so far, in order. */
    val videoConnections = mutableListOf<ScriptedVideoConnection>()
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
            if (route is ControlRoute.Video) {
                check(videoReachable) { "the picture connection is refused" }
                return@ControlConnector ScriptedVideoConnection().also { videoConnections += it }
            }
            check(reachable) { "the host is not reachable" }
            if (route is ControlRoute.Direct && route.address in refusing) throw java.net.ConnectException("refused")
            mac.newConnection()
        },
        discovery = object : Discovery {
            override fun hosts(): Flow<DiscoveredHost> = if (discoveryFails) {
                flow { throw java.io.IOException("NSD discovery failed with code 0") }
            } else if (!hostVisible) {
                flow { awaitCancellation() }
            } else {
                flow {
                    delay(discoveryDelayMillis)
                    emit(DiscoveredHost(ScriptedPairingHost.HOST_ID, HOST_NAME, protocolVersion = 1, address = hostAddress))
                }
            }
        },
        sink = sink,
        downloads = DownloadWriter { offset, bytes -> downloads[offset] = bytes },
        relay = RelayPorts(signalling, datagrams) { entitlement },
        log = { logged += it },
        lanReached = { hostId, address -> reachedOnLan[hostId] = address },
    )

    val controller = SessionController(scope, target, ports, history)

    companion object {
        const val CLIENT_ID = "11111111-2222-4333-8444-555555555555"
        const val CLIENT_NAME = "Phone"
        const val HOST_NAME = "Studio"
        val LAN_ADDRESS = PeerAddress("192.0.2.10", 7000)
    }
}
