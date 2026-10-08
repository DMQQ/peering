import Foundation

/// Codex lists the models it offers in its own cache, refreshed by the CLI; there is no command that prints them.
enum CodexModelCache {
    static func visibleModels() -> [String] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        guard let data = FileManager.default.contents(atPath: home + "/models_cache.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { entry in
            guard entry["visibility"] as? String == "list" else { return nil }
            return entry["slug"] as? String
        }
    }
}
