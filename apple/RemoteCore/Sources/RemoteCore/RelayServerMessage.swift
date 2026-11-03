import Foundation

/// Messages received from `peeringd` over the signalling WebSocket.
public enum RelayServerMessage: Sendable, Equatable, Decodable {
    case registered(sessionTTLSeconds: UInt64)
    case sessionReady(RelaySession)
    case hostOffline(deviceID: String)
    case peerAddress(RelayPeerAddress)
    /// `online: false` is about registration with the relay, not the Mac's reachability.
    case hostPresence(deviceID: String, online: Bool)
    case pong
    case referral(RelayReferral)
    case error(code: String, message: String)
    /// Answers a `notifyActivity` that was not sent.
    case activityRefused(RelayActivityRefusal, requestId: String? = nil)

    private enum CodingKeys: String, CodingKey {
        case type, controlHost, controlPort, videoHost, videoPort
        case sessionTTLSeconds = "sessionTtlSeconds"
        case controlToken, videoToken, remainingSeconds
        case deviceID = "deviceId"
        case hostID = "hostId"
        case online
        case code, message, reason, requestId
        case host, port
        case bonusSeconds, bonusEndsAt, redeemed, invitesEarned, invitesMax
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "registered":
            self = .registered(sessionTTLSeconds: try container.decode(UInt64.self, forKey: .sessionTTLSeconds))
        case "sessionReady":
            guard let controlToken = Self.token(
                try container.decode(String.self, forKey: .controlToken)
            ), let videoToken = Self.token(
                try container.decode(String.self, forKey: .videoToken)
            ) else {
                throw RelayProtocolError.invalidToken
            }
            self = .sessionReady(RelaySession(
                controlHost: try container.decode(String.self, forKey: .controlHost),
                controlPort: try container.decode(UInt16.self, forKey: .controlPort),
                videoHost: try container.decode(String.self, forKey: .videoHost),
                videoPort: try container.decode(UInt16.self, forKey: .videoPort),
                controlToken: controlToken,
                videoToken: videoToken,
                remainingSeconds: try container.decodeIfPresent(UInt64.self, forKey: .remainingSeconds)
            ))
        case "hostOffline":
            self = .hostOffline(deviceID: try container.decode(String.self, forKey: .deviceID))
        case "peerAddress":
            self = .peerAddress(RelayPeerAddress(
                host: try container.decode(String.self, forKey: .host),
                port: try container.decode(UInt16.self, forKey: .port)
            ))
        case "hostPresence":
            self = .hostPresence(
                deviceID: try container.decode(String.self, forKey: .hostID),
                online: try container.decode(Bool.self, forKey: .online)
            )
        case "pong":
            self = .pong
        case "referral":
            self = .referral(RelayReferral(
                code: try container.decode(String.self, forKey: .code),
                bonusSeconds: try container.decode(TimeInterval.self, forKey: .bonusSeconds),
                bonusEndsAt: try container.decodeIfPresent(TimeInterval.self, forKey: .bonusEndsAt)
                    .map(Date.init(timeIntervalSince1970:)),
                redeemed: try container.decode(Bool.self, forKey: .redeemed),
                invitesEarned: try container.decode(Int.self, forKey: .invitesEarned),
                invitesMax: try container.decode(Int.self, forKey: .invitesMax)
            ))
        case "error":
            self = .error(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        case "activityRefused":
            self = .activityRefused(
                try container.decode(RelayActivityRefusal.self, forKey: .reason),
                requestId: try container.decodeIfPresent(String.self, forKey: .requestId)
            )
        default:
            throw RelayProtocolError.unknownMessage(type)
        }
    }

    /// Sixteen bytes, spelled as thirty-two hex digits. Both guards are load-bearing.
    ///
    /// The count is in characters, the unit the loop moves in: a string of thirty-two bytes can be
    /// fewer than thirty-two characters, and walking sixteen times then reads past the end and takes
    /// the process down. Every character must also be an ASCII hex digit, because
    /// `UInt8(_:radix:)` accepts a leading `+`, so sixteen `+1`s would decode to one-bytes.
    private static func token(_ hex: String) -> Data? {
        guard hex.count == 32, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        var index = hex.startIndex
        for _ in 0..<16 {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        return Data(bytes)
    }
}
