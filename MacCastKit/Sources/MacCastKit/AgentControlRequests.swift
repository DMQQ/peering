import Foundation

/// Claude's `control_request` traffic: what was asked, so the matching `control_response` finds its answer.
public struct AgentControlRequests {
    public enum Outcome {
        case success([String: Any]?)
        case failure(String?)
    }

    private var waiting: [String: (Outcome) -> Void] = [:]

    public init() {}

    /// The line to send. `completion` runs when the response with this request's id arrives.
    public mutating func make(
        subtype: String,
        fields: [String: Any] = [:],
        completion: ((Outcome) -> Void)? = nil
    ) -> String? {
        let id = UUID().uuidString
        var body = fields
        body["subtype"] = subtype
        guard let line = Self.encode(["type": "control_request", "request_id": id, "request": body]) else { return nil }
        if let completion { waiting[id] = completion }
        return line
    }

    /// True when the line answered one of this side's own requests, which must not reach the transcript.
    public mutating func resolve(line: String) -> Bool {
        guard !waiting.isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              let id = response["request_id"] as? String,
              let completion = waiting.removeValue(forKey: id)
        else { return false }

        if response["subtype"] as? String == "success" {
            completion(.success(response["response"] as? [String: Any]))
        } else {
            let message = (response["error"] as? String) ?? (response["response"] as? [String: Any])?["error"] as? String
            completion(.failure(message))
        }
        return true
    }

    public static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
