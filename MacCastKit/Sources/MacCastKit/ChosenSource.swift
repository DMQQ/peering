import Foundation
import RemoteCore

/// The one source a Mac was last left on, remembered for the next time it is opened.
public enum ChosenSourceStore {
    private static let key = "Peering.chosenSources"

    private static func sources() -> [String: CaptureSource] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: CaptureSource].self, from: data)
        else { return [:] }
        return stored
    }

    public static func load(hostID: String) -> CaptureSource? {
        sources()[hostID]
    }

    public static func save(_ source: CaptureSource?, hostID: String) {
        var stored = sources()
        if let source {
            stored[hostID] = source
        } else {
            stored.removeValue(forKey: hostID)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public enum ChosenSource {
    /// The remembered source, if this Mac still has it.
    public static func restored(_ source: CaptureSource?, into catalog: CaptureCatalog?) -> CaptureSource? {
        guard let source, let catalog else { return nil }
        return catalog.descriptor(for: source) == nil ? nil : source
    }
}
