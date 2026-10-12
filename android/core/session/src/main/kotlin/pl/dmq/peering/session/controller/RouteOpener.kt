package pl.dmq.peering.session.controller

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import pl.dmq.peering.session.ports.ControlTransport
import pl.dmq.peering.session.ports.PeerAddress
import pl.dmq.peering.session.relay.RelayConnect
import pl.dmq.peering.session.relay.RelaySessionException
import kotlin.time.Duration.Companion.seconds

/** Turns a [ConnectTarget] into an open control connection, asking the relay or the local network as the target needs. */
internal class RouteOpener(private val target: ConnectTarget, private val ports: SessionPorts) {
    suspend fun open(): OpenedRoute = when (target) {
        is ConnectTarget.Lan -> direct(target.hostId?.let { fresh(it) } ?: target.address)
        is ConnectTarget.Pairing -> direct(guarded { discover(target.hostId) })
        is ConnectTarget.Relay -> relayed(target.hostId)
    }

    private suspend fun direct(address: PeerAddress): OpenedRoute {
        val (transport, reached) = guarded { dial(address) }
        return OpenedRoute(transport, target.path, reached, ByteArray(0), datagrams = null)
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
    private suspend fun fresh(hostId: String): PeerAddress? = withTimeoutOrNull(FRESH_TIMEOUT) {
        ports.discovery.hosts().first { it.id == hostId }
    }?.address

    private suspend fun relayed(hostId: String): OpenedRoute {
        val relay = checkNotNull(ports.relay) { "a relay target needs the relay ports" }
        val session = guarded {
            RelayConnect(relay.signalling, ports.identity, ports.clock)
                .requestSession(hostId, ports.identity.clientId, relay.entitlement())
        }
        val transport = guarded { ports.control.open(ControlRoute.Relayed(session.controlHandoff())) }
        return OpenedRoute(transport, target.path, session.video, session.videoTokenBytes, relay.datagrams)
    }

    private suspend fun discover(hostId: String): PeerAddress {
        val found = withTimeoutOrNull(DISCOVERY_TIMEOUT) {
            ports.discovery.hosts().first { it.id == hostId }
        } ?: throw ConnectFailure(SessionFailure.HostNotFound)
        return found.address
    }

    /** Every failure leaves here as a [ConnectFailure], so the caller maps one type and never a raw exception. */
    private suspend fun <T> guarded(block: suspend () -> T): T = try {
        block()
    } catch (failure: ConnectFailure) {
        throw failure
    } catch (failure: RelaySessionException) {
        throw ConnectFailure(relayFailure(failure))
    } catch (failure: CancellationException) {
        throw failure
    } catch (failure: Exception) {
        throw ConnectFailure(SessionFailure.ConnectionFailed(ConnectFailureKind.of(failure), ConnectFailureKind.describe(failure)))
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
    }
}
