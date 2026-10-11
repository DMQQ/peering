package pl.dmq.peering.session.video

/** The result of offering one relayed datagram to the lanes. [authenticated] is false for one that was rejected. */
class DatagramOutcome(val authenticated: Boolean, val outputs: List<LaneOutput>)
