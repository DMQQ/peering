import Foundation

/// An invite code as a person types and reads it, and the answers the relay can give to using one.
public enum ReferralCode {
    /// Eight characters, no separators, upper case: what the relay compares against. People type spaces and hyphens and lower case.
    public static func canonical(_ typed: String) -> String {
        typed.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    public static var length: Int { 8 }

    public static func isComplete(_ typed: String) -> Bool {
        canonical(typed).count == length
    }

    /// `ABCD-EFGH`: two groups of four read and dictate more easily than eight in a row.
    public static func display(_ code: String) -> String {
        let plain = canonical(code)
        guard plain.count == length else { return plain }
        return "\(plain.prefix(4))-\(plain.suffix(4))"
    }
}

/// Why the relay turned a redemption away, in words for the person who typed the code.
public enum ReferralRefusal: Equatable, Sendable {
    case unknownCode
    case ownCode
    case alreadyRedeemed
    case needsKeyProof
    case busy
    case unavailable

    /// The relay's error `code` field.
    public init(code: String) {
        switch code {
        case "referralUnknownCode": self = .unknownCode
        case "referralOwnCode": self = .ownCode
        case "referralAlreadyRedeemed": self = .alreadyRedeemed
        case "proofRequired", "proofStale", "proofInvalid": self = .needsKeyProof
        case "referralsBusy", "tooManyRequests": self = .busy
        default: self = .unavailable
        }
    }

    public var message: String {
        switch self {
        case .unknownCode: return String(localized: "That code does not match anyone. Check it and try again.")
        case .ownCode: return String(localized: "That is your own code. Send it to a friend instead.")
        case .alreadyRedeemed: return String(localized: "You have already used a code on this device.")
        case .needsKeyProof: return String(localized: "This device could not prove who it is. Check that the clock is right and try again.")
        case .busy: return String(localized: "Too many people are doing this right now. Try again in a while.")
        case .unavailable: return String(localized: "The relay could not be reached. Try again in a moment.")
        }
    }
}

/// The extra daily relay time a referral has earned, which stops counting when its grants end.
public enum ReferralBonus {
    public static func activeSeconds(bonusSeconds: TimeInterval, endsAt: Date?, now: Date = Date()) -> TimeInterval {
        guard let endsAt, endsAt > now else { return 0 }
        return bonusSeconds
    }
}
