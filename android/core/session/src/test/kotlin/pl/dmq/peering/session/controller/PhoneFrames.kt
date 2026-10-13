package pl.dmq.peering.session.controller

import pl.dmq.peering.session.connection.HandshakeFrames
import pl.dmq.peering.wire.ClientHello
import pl.dmq.peering.wire.Frame
import pl.dmq.peering.wire.MessageKind
import pl.dmq.peering.wire.RemoteCommand

internal fun List<Frame>.ofKind(kind: MessageKind): List<Frame> = filter { it.kind == kind }

/** The commands the phone sent, in order. */
internal fun List<Frame>.commands(): List<RemoteCommand> =
    ofKind(MessageKind.Command).map { RemoteCommand.parse(it.payload.decodeToString()) }

internal fun List<Frame>.clientHellos(): List<ClientHello> =
    ofKind(MessageKind.ClientHello).mapNotNull { HandshakeFrames.decode(it, ClientHello.serializer()) }
