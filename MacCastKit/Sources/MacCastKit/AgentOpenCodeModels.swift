import Foundation

/// Reading what `opencode export <session>` and `opencode models --verbose` say, which is where
/// the model a session ran and that model's context window live. The run stream names neither.
public enum AgentOpenCodeModels {
    public struct ModelID: Equatable, Sendable {
        public let provider: String
        public let model: String
        public var listed: String { "\(provider)/\(model)" }
    }

    /// The model of the last assistant message in an export.
    public static func lastModel(inExport data: Data) -> ModelID? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]]
        else { return nil }
        for message in messages.reversed() {
            guard let info = message["info"] as? [String: Any],
                  info["role"] as? String == "assistant",
                  let provider = info["providerID"] as? String,
                  let model = info["modelID"] as? String
            else { continue }
            return ModelID(provider: provider, model: model)
        }
        return nil
    }

    /// The context window of one model in the verbose listing, which is a `provider/model` line
    /// followed by that model's JSON.
    public static func contextWindow(of model: ModelID, inListing listing: String) -> Int? {
        var inside = false
        var block = ""
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            let isHeader = line.first.map { !$0.isWhitespace && $0 != "{" && $0 != "}" } ?? false
            if isHeader {
                if inside { break }
                inside = line.trimmingCharacters(in: .whitespaces) == model.listed
                continue
            }
            if inside { block += line + "\n" }
        }
        guard inside, let data = block.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limit = json["limit"] as? [String: Any]
        else { return nil }
        return limit["context"] as? Int
    }
}
