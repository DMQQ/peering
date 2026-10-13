package pl.dmq.peering.session.controller

/** Carries a [SessionFailure] out of the code that opens a route, so the caller can map it to a phase. */
class ConnectFailure(val failure: SessionFailure) : Exception(null, null)
