package pl.dmq.peering.session.controller

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import pl.dmq.peering.session.history.SessionRecord
import pl.dmq.peering.session.ports.ControlTransport
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.ports.SessionLog
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.relay.RelaySessionException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** Turns a [ConnectTarget] into an open control connection, asking the relay or the local network as the target needs. */
internal class RouteOpener(
    private val target: ConnectTarget,
    private val ports: SessionPorts,
    private val log: SessionLog = ports.log,
    private val reuseDiscovered: Boolean = true,
) {
    suspend fun open(): OpenedRoute = guarded { openRoute() }

    private suspend fun openRoute(): OpenedRoute = when (target) {
        is ConnectTarget.Lan -> direct(target.hostId?.let { fresh(it) } ?: target.address)
        is ConnectTarget.Pairing -> direct(discover(target.hostId))
        is ConnectTarget.Relay -> raced(DialInputs(null, null, relayAllowed = true, pairElsewhere = true))
        is ConnectTarget.Paired -> raced(
            DialInputs(
                discovered = target.discovered.takeIf { reuseDiscovered } ?: seenSoon(target),
                remembered = target.remembered,
                relayAllowed = target.relayAllowed && ports.relay != null,
            ),
        )
    }

    /** Dials by the plan for [inputs]; a plan with no route at all means the host is not where this phone can look. */
    private suspend fun raced(inputs: DialInputs): OpenedRoute {
        val steps = DialPlanner.plan(inputs)
        if (steps.isEmpty()) throw ConnectFailure(SessionFailure.HostNotFound)
        return RouteRace(steps.map { step -> RouteRace.Attempt(step.startsAfter) { attempt(step) } }).run()
    }

    private suspend fun attempt(step: DialStep): OpenedRoute = when (step) {
        is DialStep.Lan -> withTimeoutOrNull(step.timeout) { direct(step.address) } ?: throw ConnectFailure(
            SessionFailure.ConnectionFailed(ConnectFailureKind.Timeout, "No answer from ${step.address.host} on the local network"),
        )
        is DialStep.Relay -> relayed(target.hostId ?: error("a relay dial needs a host"))
    }

    /** With nothing known about where the host is, discovery gets a moment before the relay is dialled past a host on this network. */
    private suspend fun seenSoon(target: ConnectTarget.Paired): PeerAddress? =
        if (reuseDiscovered && target.remembered != null) null else lookUp(target.hostId, LOCAL_GRACE)

    private suspend fun direct(address: PeerAddress): OpenedRoute {
        log.log("dialling ${address.host}:${address.port} on the local network")
        val (transport, reached) = guarded { dial(address) }
        return OpenedRoute(transport, SessionRecord.Path.LAN, reached, ByteArray(0), datagrams = null)
    }

    /** Tries the resolved port, then the protocol default when the first refuses. Each attempt is made by the connector, which logs it. */
    private suspend fun dial(address: PeerAddress): Pair<ControlTransport, PeerAddress> {
        var failure: Exception? = null
        for (candidate in ConnectAddresses.candidates(address)) {
            try {
                return ports.control.open(ControlRoute.Direct(candidate)) to candidate
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                failure = error
                if (!ConnectAddresses.refused(error)) break
            }
        }
        throw checkNotNull(failure)
    }

    /** The address [hostId] has on the network right now, or null when it was not seen in time. Never a remembered one. */
    private suspend fun fresh(hostId: String): PeerAddress? = lookUp(hostId, FRESH_TIMEOUT)

    /** Discovery that cannot start reads as a host that was not seen, so the dial falls back to the next route. */
    private suspend fun lookUp(hostId: String, timeout: Duration): PeerAddress? = try {
        withTimeoutOrNull(timeout) { ports.discovery.hosts().first { it.id == hostId } }?.address
    } catch (failure: CancellationException) {
        throw failure
    } catch (failure: Exception) {
        log.log("discovery failed: ${ConnectFailureKind.describe(failure)}")
        null
    }

    private suspend fun relayed(hostId: String): OpenedRoute {
        val relay = checkNotNull(ports.relay) { "a relay target needs the relay ports" }
        log.log("asking the relay for a session to $hostId")
        val session = guarded {
            RelayConnect(relay.signalling, ports.identity, ports.clock)
                .requestSession(hostId, ports.identity.clientId, relay.entitlement())
        }
        session.remainingSeconds?.let(relay.onRemainingSeconds)
        val transport = guarded { ports.control.open(ControlRoute.Relayed(session.controlHandoff())) }
        return OpenedRoute(transport, SessionRecord.Path.RELAY, session.video, session.videoTokenBytes, relay.datagrams)
    }

    private suspend fun discover(hostId: String): PeerAddress {
        return lookUp(hostId, DISCOVERY_TIMEOUT) ?: run {
            log.log("host $hostId not seen on the local network in $DISCOVERY_TIMEOUT")
            throw ConnectFailure(SessionFailure.HostNotFound)
        }
    }

    /** Every failure leaves here as a [ConnectFailure], so the caller maps one type and never a raw exception. */
    private suspend fun <T> guarded(block: suspend () -> T): T = try {
        block()
    } catch (failure: ConnectFailure) {
        throw failure
    } catch (failure: RelaySessionException) {
        log.log("relay session failed: $failure")
        throw ConnectFailure(relayFailure(failure))
    } catch (failure: CancellationException) {
        throw failure
    } catch (failure: Exception) {
        val kind = ConnectFailureKind.of(failure)
        log.log("connect failed, $kind: ${ConnectFailureKind.describe(failure)}")
        throw ConnectFailure(SessionFailure.ConnectionFailed(kind, ConnectFailureKind.describe(failure)))
    }

    private fun relayFailure(failure: RelaySessionException): SessionFailure = when (failure) {
        RelaySessionException.QuotaExceeded -> SessionFailure.Quota
        RelaySessionException.VersionMismatch -> SessionFailure.VersionMismatch
        is RelaySessionException.HostOffline -> SessionFailure.HostOffline(failure.hostId)
        is RelaySessionException.Refused -> SessionFailure.RelayRefused(failure.code, failure.detail)
        is RelaySessionException.UnexpectedReply -> SessionFailure.RelayRefused("unexpectedReply", failure.type)
    }

    private companion object {
        val DISCOVERY_TIMEOUT = 10.seconds
        val FRESH_TIMEOUT = 3.seconds
        val LOCAL_GRACE = 3.seconds
    }
}
