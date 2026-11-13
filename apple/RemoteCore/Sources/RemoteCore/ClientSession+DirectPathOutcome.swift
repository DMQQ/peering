extension ClientSession.DirectPath {
    /// How long the attempt is given before it is called failed. A punch that works opens within a couple of seconds.
    public static let verdictAfter: Double = 8

    /// What an attempt still in progress comes to when its time is up: a failure with a reason, instead of "nothing back yet" for the rest of the session. Anything already decided stays.
    public func verdict() -> Self {
        switch self {
        case .noAddress: .gaveUp(.relayHasNoAddress)
        case .probing(let peer): .gaveUp(.noAnswer(peer: peer))
        case .notTried, .addressUnusable, .open, .gaveUp: self
        }
    }

    /// Whether the attempt has an outcome worth recording: it worked, or it failed for a reason.
    public var isResolved: Bool {
        switch self {
        case .open, .gaveUp, .addressUnusable: true
        case .notTried, .noAddress, .probing: false
        }
    }

    /// A stable name for analytics, with no addresses in it.
    public var outcomeName: String {
        switch self {
        case .notTried: "not_tried"
        case .noAddress: "no_address"
        case .probing: "probing"
        case .addressUnusable: "address_unusable"
        case .open: "open"
        case .gaveUp(.relayHasNoAddress): "relay_has_no_address"
        case .gaveUp(.noAnswer): "no_answer"
        }
    }
}
