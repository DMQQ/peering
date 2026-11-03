import Foundation

public struct RelayEntitlement: Sendable, Equatable {
    public let plan: String?
    public let jwsRepresentation: String?
    public let apiKey: String?

    public init(
        plan: String? = nil,
        jwsRepresentation: String? = nil,
        apiKey: String? = nil
    ) {
        self.plan = plan
        self.jwsRepresentation = jwsRepresentation
        self.apiKey = apiKey
    }
}

/// The part of a push that lets the phone answer an agent's approval request from the notification.
public struct RelayPushAction: Sendable, Equatable {
    public let category: String
    public let sessionID: String
    public let approvalID: String
    /// The answers of a question no fixed category has buttons for; the phone's notification extension makes them buttons.
    public let answers: [String]
    /// A multi-question ask the phone asks one question at a time from the lock screen.
    public let questions: [RelayPushQuestion]

    public init(category: String, sessionID: String, approvalID: String, answers: [String] = [], questions: [RelayPushQuestion] = []) {
        self.category = category
        self.sessionID = sessionID
        self.approvalID = approvalID
        self.answers = answers
        self.questions = questions
    }
}

/// One question of a pushed ask, sent as `{"q": question, "a": [answers]}`, the shape the phone reads back.
public struct RelayPushQuestion: Codable, Sendable, Equatable {
    /// The relay refuses the whole push past these, so a question over them is not sent.
    public static let maxQuestionBytes = 512
    public static let maxAnswerBytes = 160

    public let question: String
    public let answers: [String]

    public init(question: String, answers: [String]) {
        self.question = question
        self.answers = answers
    }

    public var fitsTheRelay: Bool {
        question.utf8.count <= Self.maxQuestionBytes && answers.allSatisfy { $0.utf8.count <= Self.maxAnswerBytes }
    }

    private enum CodingKeys: String, CodingKey {
        case question = "q"
        case answers = "a"
    }
}

/// Everything both apps need after `peeringd` introduces them.
public struct RelaySession: Sendable, Equatable {
    public let controlHost: String
    public let controlPort: UInt16
    public let videoHost: String
    public let videoPort: UInt16
    public let controlToken: Data
    public let videoToken: Data
    /// Seconds left in the relay's current one-day window, referral bonus included. Absent from older relays and for unmetered plans.
    public let remainingSeconds: UInt64?

    public init(
        controlHost: String,
        controlPort: UInt16,
        videoHost: String,
        videoPort: UInt16,
        controlToken: Data,
        videoToken: Data,
        remainingSeconds: UInt64? = nil
    ) {
        self.controlHost = controlHost
        self.controlPort = controlPort
        self.videoHost = videoHost
        self.videoPort = videoPort
        self.controlToken = controlToken
        self.videoToken = videoToken
        self.remainingSeconds = remainingSeconds
    }
}

public struct RelayPeerAddress: Sendable, Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public enum RelayProtocolError: LocalizedError, Sendable, Equatable {
    case unknownMessage(String)
    case invalidToken

    public var errorDescription: String? {
        switch self {
        case .unknownMessage(let type): return "The relay sent an unknown message type: \(type)."
        case .invalidToken: return "The relay sent an invalid session token."
        }
    }
}

/// The JSON codec for the relay's public WebSocket contract.
public enum RelayMessageCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
