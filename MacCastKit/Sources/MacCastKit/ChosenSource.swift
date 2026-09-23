import Foundation
import RemoteCore

/// The one source a Mac was last left on, remembered for the next time it is opened.
///
/// Beside the arrangement, because the two answer the same question: both are kept per Mac and both
/// are thinned by the catalogue on the way back in. What is kept here is the single source, not a
/// list; a second source in it is an arrangement, which belongs in ``MosaicArrangementStore``.
public enum ChosenSourceStore {
    private static let key = "Peering.chosenSources"

    /// Every Mac's source, by the Mac's own id. One dictionary rather than a key per Mac: a key
    /// built from an id could collide with anything else in the defaults, and the ids are not known
    /// until a Mac answers.
    private static func sources() -> [String: CaptureSource] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: CaptureSource].self, from: data)
        else { return [:] }
        return stored
    }

    /// What is remembered for one Mac, or nothing when nothing has been chosen there.
    public static func load(hostID: String) -> CaptureSource? {
        sources()[hostID]
    }

    /// Remembers one source against one Mac, or forgets the Mac's when handed nothing.
    public static func save(_ source: CaptureSource?, hostID: String) {
        var stored = sources()
        if let source {
            stored[hostID] = source
        } else {
            // Forgetting is an assignment of nothing, the same shape as emptying an arrangement:
            // a separate `forget` call is one more thing a caller can leave out, and leaving it out
            // leaves a Mac opening on a source nobody asked for.
            stored.removeValue(forKey: hostID)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public enum ChosenSource {
    /// The remembered source, if this Mac still has it.
    ///
    /// The catalogue is the filter: a window id and a process id outlive neither a restart nor a
    /// quit, and the catalogue the Mac has just sent is the only thing in a session that says
    /// whether the source still exists. Applied to a display as well, since one rule about ids is
    /// worth more than a rule per kind kept in step with the catalogue's three lists.
    public static func restored(_ source: CaptureSource?, into catalog: CaptureCatalog?) -> CaptureSource? {
        guard let source, let catalog else { return nil }
        return catalog.descriptor(for: source) == nil ? nil : source
    }
}
